import Foundation

/// Tells VOID when macOS is running low on memory, so it can put the deep brain to sleep.
final class MemoryMonitor {
    private let source: DispatchSourceMemoryPressure

    init(handler: @escaping (DispatchSource.MemoryPressureEvent) -> Void) {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )
        source.setEventHandler {
            handler(source.data)
        }
        source.resume()
        self.source = source
    }

    deinit {
        source.cancel()
    }
}
