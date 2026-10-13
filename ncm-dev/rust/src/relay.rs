// SPDX-License-Identifier: GPL-3.0-only
//! Native app -> S3 streams. Only the S3 may dial developer services.
use crate::{DialFuture, NcmConnector, Purpose, Stream};
use std::{
    io,
    net::{Ipv4Addr, SocketAddr},
    sync::atomic::{AtomicBool, Ordering},
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpSocket,
};
use zeroize::Zeroizing;

pub struct RelayConnector {
    interface_index: u32,
    generation: u32,
    index: u8,
    nonce: String,
    opened: AtomicBool,
    tunnel_opened: AtomicBool,
    local: Ipv4Addr,
    relay: SocketAddr,
    lockdown: bool,
    relay_token: Option<Zeroizing<Vec<u8>>>,
}
impl RelayConnector {
    pub fn new(interface_index: u32, generation: u32, index: u8) -> io::Result<Self> {
        if interface_index == 0 || generation == 0 || index >= 16 {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        Ok(Self {
            interface_index,
            generation,
            index,
            nonce: uuid::Uuid::new_v4().simple().to_string(),
            opened: AtomicBool::new(false),
            tunnel_opened: AtomicBool::new(false),
            local: Ipv4Addr::new(192, 168, 7, 2),
            relay: ([192, 168, 7, 1], 28767).into(),
            lockdown: false,
            relay_token: None,
        })
    }
    /// Separate fixed hotspot subnet. Every stream authenticates to the board
    /// before NR1; no default route, USB fallback or credential-bearing errors.
    pub fn new_wifi_configured(
        interface_index: u32,
        generation: u32,
        index: u8,
        local: Ipv4Addr,
        board: Ipv4Addr,
        token: &[u8],
    ) -> io::Result<Self> {
        if local != Ipv4Addr::new(192, 168, 8, 2)
            || board != Ipv4Addr::new(192, 168, 8, 1)
            || token.len() != 64
            || !token
                .iter()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(b))
        {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        let mut connector = Self::new(interface_index, generation, index)?;
        connector.local = local;
        connector.relay = (board, 28767).into();
        connector.relay_token = Some(Zeroizing::new(token.to_vec()));
        Ok(connector)
    }
    /// Fixed peer .2:62078 through NL1, independent of RP discovery/identity.
    pub fn new_lockdown(interface_index: u32) -> io::Result<Self> {
        let mut connector = Self::new(interface_index, 1, 0)?;
        connector.lockdown = true;
        Ok(connector)
    }
    #[cfg(any(test, feature = "offline-fixtures"))]
    pub(crate) fn loopback(port: u16) -> Self {
        Self {
            interface_index: 0,
            generation: 7,
            index: 0,
            nonce: uuid::Uuid::new_v4().simple().to_string(),
            opened: AtomicBool::new(false),
            tunnel_opened: AtomicBool::new(false),
            local: Ipv4Addr::LOCALHOST,
            relay: (Ipv4Addr::LOCALHOST, port).into(),
            lockdown: false,
            relay_token: None,
        }
    }
    async fn open(&self, purpose: Purpose) -> io::Result<Stream> {
        let line = match purpose {
            Purpose::PairVerify => {
                if self.lockdown || self.opened.swap(true, Ordering::SeqCst) {
                    return Err(io::ErrorKind::AlreadyExists.into());
                }
                format!(
                    "NR1 OPEN {} {} {}\n",
                    self.generation, self.index, self.nonce
                )
            }
            Purpose::NegotiatedTunnel { port } => {
                if port == 0
                    || self.lockdown
                    || !self.opened.load(Ordering::SeqCst)
                    || self.tunnel_opened.swap(true, Ordering::SeqCst)
                {
                    return Err(io::ErrorKind::InvalidInput.into());
                }
                format!("NR1 TUNNEL {} {}\n", self.nonce, port)
            }
            Purpose::LockdownSession => {
                if !self.lockdown || self.opened.swap(true, Ordering::SeqCst) {
                    return Err(io::ErrorKind::InvalidInput.into());
                }
                format!("NL1 OPEN {}\n", self.nonce)
            }
        };
        let socket = TcpSocket::new_v4()?;
        if self.interface_index != 0 {
            bind_interface(&socket, self.interface_index, self.local)?;
        }
        socket.bind((self.local, 0).into())?;
        let mut stream = tokio::time::timeout(Duration::from_secs(4), socket.connect(self.relay))
            .await
            .map_err(|_| io::Error::from(io::ErrorKind::TimedOut))??;
        if stream.local_addr()?.ip() != self.local {
            return Err(io::ErrorKind::PermissionDenied.into());
        }
        stream.set_nodelay(true)?;
        tokio::time::timeout(Duration::from_secs(4), async {
            if let Some(token) = &self.relay_token {
                stream.write_all(b"NW1 AUTH ").await?;
                stream.write_all(token.as_slice()).await?;
                stream.write_all(b"\n").await?;
            }
            stream.write_all(line.as_bytes()).await?;
            let mut reply = Vec::new();
            while reply.len() < 64 {
                let c = stream.read_u8().await?;
                reply.push(c);
                if c == b'\n' {
                    break;
                }
            }
            if reply
                != (if self.lockdown {
                    b"NL1 OK\n"
                } else {
                    b"NR1 OK\n"
                })
            {
                return Err(io::Error::from(io::ErrorKind::ConnectionRefused));
            }
            Ok::<(), io::Error>(())
        })
        .await
        .map_err(|_| io::Error::from(io::ErrorKind::TimedOut))??;
        Ok(Box::new(stream))
    }
}
impl NcmConnector for RelayConnector {
    fn connect(&self, purpose: Purpose) -> DialFuture<'_> {
        Box::pin(self.open(purpose))
    }
}
#[cfg(target_vendor = "apple")]
fn bind_interface(socket: &TcpSocket, index: u32, local: Ipv4Addr) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    // Explicit Darwin socket binding. Never fall back if permission/interface
    // validation fails. Swift independently validates the selected link type
    // and exact USB/hotspot local address before entering this backend.
    let mut head: *mut libc::ifaddrs = std::ptr::null_mut();
    if unsafe { libc::getifaddrs(&mut head) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let mut current = head;
    let mut matches = 0;
    while !current.is_null() {
        let row = unsafe { &*current };
        if !row.ifa_addr.is_null()
            && !row.ifa_name.is_null()
            && unsafe { (*row.ifa_addr).sa_family } == libc::AF_INET as u8
            && unsafe { libc::if_nametoindex(row.ifa_name) } == index
        {
            let addr = unsafe { &*(row.ifa_addr as *const libc::sockaddr_in) };
            let mask = if row.ifa_netmask.is_null() {
                0
            } else {
                unsafe {
                    (*(row.ifa_netmask as *const libc::sockaddr_in))
                        .sin_addr
                        .s_addr
                }
            };
            let flags = row.ifa_flags as i32;
            if addr.sin_addr.s_addr.to_ne_bytes() == local.octets()
                && mask.to_ne_bytes() == [255, 255, 255, 0]
                && flags & (libc::IFF_UP | libc::IFF_RUNNING) == (libc::IFF_UP | libc::IFF_RUNNING)
                && flags & (libc::IFF_LOOPBACK | libc::IFF_POINTOPOINT) == 0
            {
                matches += 1;
            }
        }
        current = row.ifa_next;
    }
    unsafe { libc::freeifaddrs(head) };
    if matches != 1 {
        return Err(io::ErrorKind::AddrNotAvailable.into());
    }
    let result = unsafe {
        libc::setsockopt(
            socket.as_raw_fd(),
            libc::IPPROTO_IP,
            libc::IP_BOUND_IF,
            &index as *const _ as *const libc::c_void,
            std::mem::size_of_val(&index) as libc::socklen_t,
        )
    };
    if result != 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}
#[cfg(not(target_vendor = "apple"))]
fn bind_interface(_: &TcpSocket, _: u32, _: Ipv4Addr) -> io::Result<()> {
    Err(io::ErrorKind::Unsupported.into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;
    #[test]
    fn wifi_configuration_rejects_usb_subnet_and_invalid_credentials() {
        let local = Ipv4Addr::new(192, 168, 8, 2);
        let board = Ipv4Addr::new(192, 168, 8, 1);
        let token = [b'a'; 64]; // Public synthetic relay credential only.
        let connector =
            RelayConnector::new_wifi_configured(77, 7, 0, local, board, &token).unwrap();
        assert_eq!(connector.local, local);
        assert_eq!(connector.relay, (board, 28767).into());
        assert!(RelayConnector::new_wifi_configured(0, 7, 0, local, board, &token).is_err());
        assert!(RelayConnector::new_wifi_configured(77, 0, 0, local, board, &token).is_err());
        assert!(RelayConnector::new_wifi_configured(77, 7, 16, local, board, &token).is_err());
        assert!(
            RelayConnector::new_wifi_configured(
                77,
                7,
                0,
                Ipv4Addr::new(192, 168, 7, 2),
                board,
                &token
            )
            .is_err()
        );
        assert!(
            RelayConnector::new_wifi_configured(
                77,
                7,
                0,
                local,
                Ipv4Addr::new(192, 168, 7, 1),
                &token
            )
            .is_err()
        );
        for invalid in [
            vec![b'a'; 63],
            vec![b'a'; 65],
            vec![b'A'; 64],
            vec![b'g'; 64],
            vec![b'\n'; 64],
        ] {
            assert!(RelayConnector::new_wifi_configured(77, 7, 0, local, board, &invalid).is_err());
        }
        let usb = RelayConnector::new(77, 7, 0).unwrap();
        assert!(usb.relay_token.is_none());
        assert_eq!(usb.local, Ipv4Addr::new(192, 168, 7, 2));
    }
    #[tokio::test]
    async fn wifi_authenticates_both_streams_without_extra_ack_or_replay() {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let mut connector = RelayConnector::loopback(listener.local_addr().unwrap().port());
        connector.relay_token = Some(Zeroizing::new(vec![b'a'; 64]));
        let mock = tokio::spawn(async move {
            let mut nonce = String::new();
            for kind in 0..2 {
                let (mut peer, _) = listener.accept().await.unwrap();
                let mut auth = vec![0; 74];
                peer.read_exact(&mut auth).await.unwrap();
                assert_eq!(&auth[..9], b"NW1 AUTH ");
                assert!(auth[9..73].iter().all(|b| *b == b'a'));
                assert_eq!(auth[73], b'\n');
                let mut line = Vec::new();
                loop {
                    let b = peer.read_u8().await.unwrap();
                    if b == b'\n' {
                        break;
                    }
                    line.push(b);
                }
                let text = String::from_utf8(line).unwrap();
                let parts: Vec<_> = text.split(' ').collect();
                if kind == 0 {
                    assert_eq!(&parts[..4], &["NR1", "OPEN", "7", "0"]);
                    nonce = parts[4].to_owned();
                } else {
                    assert_eq!(parts, vec!["NR1", "TUNNEL", nonce.as_str(), "54321"]);
                }
                peer.write_all(b"NR1 OK\nNEXT").await.unwrap();
            }
        });
        let mut control = connector.connect(Purpose::PairVerify).await.unwrap();
        let mut data = [0; 4];
        control.read_exact(&mut data).await.unwrap();
        assert_eq!(&data, b"NEXT");
        let mut tunnel = connector
            .connect(Purpose::NegotiatedTunnel { port: 54321 })
            .await
            .unwrap();
        tunnel.read_exact(&mut data).await.unwrap();
        assert_eq!(&data, b"NEXT");
        assert!(connector.connect(Purpose::PairVerify).await.is_err());
        assert!(
            connector
                .connect(Purpose::NegotiatedTunnel { port: 54321 })
                .await
                .is_err()
        );
        assert!(connector.connect(Purpose::LockdownSession).await.is_err());
        mock.await.unwrap();
    }
    #[tokio::test]
    async fn wifi_auth_rejection_is_redacted_and_does_not_retry() {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let mut connector = RelayConnector::loopback(listener.local_addr().unwrap().port());
        connector.relay_token = Some(Zeroizing::new(vec![b'a'; 64]));
        let mock = tokio::spawn(async move {
            let (mut peer, _) = listener.accept().await.unwrap();
            let mut auth = [0; 74];
            peer.read_exact(&mut auth).await.unwrap();
            while peer.read_u8().await.unwrap() != b'\n' {}
            peer.write_all(b"NW1 ERR\n").await.unwrap();
        });
        let error = connector.connect(Purpose::PairVerify).await.err().unwrap();
        assert_eq!(error.kind(), io::ErrorKind::ConnectionRefused);
        assert!(!error.to_string().contains("NW1"));
        assert!(connector.connect(Purpose::PairVerify).await.is_err());
        mock.await.unwrap();
    }
    #[tokio::test]
    async fn missing_wifi_interface_fails_without_default_route_or_usb_fallback() {
        let connector = RelayConnector::new_wifi_configured(
            u32::MAX,
            7,
            0,
            Ipv4Addr::new(192, 168, 8, 2),
            Ipv4Addr::new(192, 168, 8, 1),
            &[b'a'; 64],
        )
        .unwrap();
        assert!(connector.connect(Purpose::PairVerify).await.is_err());
        assert!(connector.connect(Purpose::PairVerify).await.is_err());
    }
    #[tokio::test]
    async fn exact_two_streams_share_nonce_and_no_extra_bytes_are_consumed() {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let c = RelayConnector::loopback(listener.local_addr().unwrap().port());
        let mock = tokio::spawn(async move {
            let mut nonce = String::new();
            for kind in 0..2 {
                let (mut peer, _) = listener.accept().await.unwrap();
                let mut line = Vec::new();
                loop {
                    let b = peer.read_u8().await.unwrap();
                    if b == b'\n' {
                        break;
                    }
                    line.push(b);
                }
                let text = String::from_utf8(line).unwrap();
                let parts: Vec<_> = text.split(' ').collect();
                if kind == 0 {
                    assert_eq!(&parts[..4], &["NR1", "OPEN", "7", "0"]);
                    nonce = parts[4].to_owned();
                } else {
                    assert_eq!(parts, vec!["NR1", "TUNNEL", nonce.as_str(), "54321"]);
                }
                peer.write_all(b"NR1 OK\nNEXT").await.unwrap();
            }
        });
        let mut first = c.connect(Purpose::PairVerify).await.unwrap();
        let mut b = [0; 4];
        first.read_exact(&mut b).await.unwrap();
        assert_eq!(&b, b"NEXT");
        let mut second = c
            .connect(Purpose::NegotiatedTunnel { port: 54321 })
            .await
            .unwrap();
        second.read_exact(&mut b).await.unwrap();
        assert_eq!(&b, b"NEXT");
        assert!(c.connect(Purpose::PairVerify).await.is_err());
        assert!(
            c.connect(Purpose::NegotiatedTunnel { port: 54321 })
                .await
                .is_err()
        );
        mock.await.unwrap();
    }
    #[tokio::test]
    async fn relay_rejection_does_not_expose_stream_or_retry() {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let c = RelayConnector::loopback(listener.local_addr().unwrap().port());
        let mock = tokio::spawn(async move {
            let (mut p, _) = listener.accept().await.unwrap();
            while p.read_u8().await.unwrap() != b'\n' {}
            p.write_all(b"NR1 ERR rejected\n").await.unwrap();
        });
        assert!(c.connect(Purpose::PairVerify).await.is_err());
        assert!(c.connect(Purpose::PairVerify).await.is_err());
        mock.await.unwrap();
    }
}
