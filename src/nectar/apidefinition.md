```nim

proc startEventLoop*(threadCount = getMaxThreads())
proc stopEventLoop*()
proc getNextCompletedIoOperation*(): ptr IoOperation
proc cancel*(opOperation: ptr IoOperation): bool

proc acceptAsync*()
proc connectAsync*()
proc readFileAsync*(fd: AsyncFd, buffer: pointer, size: int, ioOperation: var IOOperation)
proc writeFileAsync*(fd: AsyncFd, buffer: pointer, size: int, ioOperation: var IOOperation)
proc recvAsync*(fd: AsyncFd, buffer: pointer, size: int, ioOperation: var IOOperation)
proc sendAsync*(fd: AsyncFd, buffer: pointer, size: int, ioOperation: var IOOperation)
proc registerTimer*(timeoutMs: int, ioOperation: var IOOperation)

## Unix only ?
proc registerHandle*(fd: AsyncFd, ioOperation: var IOOperation)
proc registerSignal*(fd: AsyncFd, ioOperation: var IOOperation)
proc registerEvent*(event: UserEvent, ioOperation: var IOOperation)
proc registerOsTimer*(timeoutMs: int, ioOperation: var IOOperation)
```