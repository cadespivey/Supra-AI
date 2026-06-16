public actor DiagnosticsLogger {
    private var events: [DiagnosticEvent] = []

    public init() {}

    public func record(_ event: DiagnosticEvent) {
        events.append(event)
    }

    public func recent(limit: Int = 100) -> [DiagnosticEvent] {
        guard limit > 0 else { return [] }
        return Array(events.suffix(limit))
    }
}
