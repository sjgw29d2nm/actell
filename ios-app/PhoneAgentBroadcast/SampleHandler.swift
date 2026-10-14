import ReplayKit
import CoreImage
import ImageIO

/// Receives only system-authorized video. Audio is discarded, never recorded.
final class SampleHandler: RPBroadcastSampleHandler {
    private var store: ReplayKitBroadcastStore?
    private var state: ReplayKitBroadcastState?
    private var watchdog: DispatchSourceTimer?
    private var lastPublishUptime: TimeInterval = 0
    private var finished = false
    private let context = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])
    private let gate = NSLock()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        do {
            guard let group = Bundle.main.object(forInfoDictionaryKey: "SuibanBroadcastAppGroup") as? String else {
                throw ReplayKitBroadcastStorageError.unavailable
            }
            let store = try ReplayKitBroadcastStore(groupIdentifier: group)
            let state = try store.beginBroadcast()
            gate.lock(); self.store = store; self.state = state; finished = false; gate.unlock()
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "suiban.broadcast.watchdog"))
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.checkLease() }
            watchdog = timer; timer.resume()
        } catch { finishLocally() }
    }
    override func broadcastPaused() { finishLocally() }
    override func broadcastResumed() { finishLocally() }
    override func broadcastFinished() { _ = invalidate() }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        gate.lock(); let store = self.store, initial = state, ended = finished; gate.unlock()
        guard !ended, let store, var state = initial else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPublishUptime >= 0.5 else { return } // One replaceable latest frame, at most 2 fps.
        do {
            _ = try store.state(session: state.session, broadcast: state.broadcast)
            guard sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
                  let pixel = CMSampleBufferGetImageBuffer(sampleBuffer),
                  let number = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.rounded() == number.doubleValue,
                  (1...8).contains(number.uint32Value), sampleBuffer.presentationTimeStamp.seconds.isFinite else {
                throw ReplayKitBroadcastStorageError.malformed
            }
            let orientation = number.uint32Value
            var image = CIImage(cvPixelBuffer: pixel).oriented(forExifOrientation: Int32(orientation))
            guard image.extent.width > 0, image.extent.height > 0 else { throw ReplayKitBroadcastStorageError.malformed }
            let scale = min(1, 1280 / max(image.extent.width, image.extent.height))
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let encoded = context.createCGImage(image, from: image.extent.integral) else { throw ReplayKitBroadcastStorageError.malformed }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw ReplayKitBroadcastStorageError.malformed }
            CGImageDestinationAddImage(destination, encoded, nil)
            guard CGImageDestinationFinalize(destination) else { throw ReplayKitBroadcastStorageError.malformed }
            state.frameUptime = now; state.sequence += 1
            state.width = encoded.width; state.height = encoded.height
            state.sourceWidth = CVPixelBufferGetWidth(pixel); state.sourceHeight = CVPixelBufferGetHeight(pixel)
            state.orientation = orientation; state.presentationSeconds = sampleBuffer.presentationTimeStamp.seconds
            state.capturedAt = Date()
            gate.lock()
            defer { gate.unlock() }
            guard !finished, self.state?.broadcast == state.broadcast else { return }
            try store.publish(image: data as Data, state: state)
            self.state = state; lastPublishUptime = now
        } catch ReplayKitBroadcastStorageError.busy { return }
        catch { finishLocally() }
    }
    private func checkLease() {
        gate.lock(); let store = self.store, state = self.state, ended = finished; gate.unlock()
        guard !ended, let store, let state else { return }
        do { _ = try store.state(session: state.session, broadcast: state.broadcast) }
        catch ReplayKitBroadcastStorageError.busy { return }
        catch { finishLocally() }
    }
    @discardableResult private func invalidate() -> Bool {
        gate.lock()
        guard !finished else { gate.unlock(); return false }
        finished = true
        let store = self.store, state = self.state
        self.store = nil; self.state = nil
        gate.unlock()
        watchdog?.cancel(); watchdog = nil
        if let store, let state { try? store.stop(session: state.session, broadcast: state.broadcast) }
        return true
    }
    private func finishLocally() {
        guard invalidate() else { return }
        finishBroadcastWithError(NSError(domain: "SuibanBroadcast", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "屏幕采集已停止；请返回随办重新授权，任务不会自动继续。"] ))
    }
}
