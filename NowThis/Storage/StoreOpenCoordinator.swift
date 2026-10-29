/// Attempts to open the configured persistent store and returns its result unchanged.
/// Recovery and retry policy remain with the caller; this coordinator has no alternate-store
/// or filesystem mutation path.
@MainActor
struct StoreOpenCoordinator<Container, Failure: Error> {
    typealias OpenOperation = () -> Result<Container, Failure>
    private let openOperation: () -> Result<Container, Failure>
    private let protectionOperation: (OpenOperation) -> Result<Container, Failure>

    init(
        protect: @escaping (OpenOperation) -> Result<Container, Failure> = { $0() },
        open: @escaping OpenOperation
    ) {
        openOperation = open
        protectionOperation = protect
    }

    func open() -> Result<Container, Failure> {
        protectionOperation(openOperation)
    }

    /// Performs exactly one additional attempt when the caller explicitly requests a retry.
    func retry() -> Result<Container, Failure> {
        open()
    }
}
