import std/epoll

const includeUnixCommons {.used.} = true
include ./unixcommons


type
  IoCompletionPool = object
    # Management
    selfThread: Thread[void]
    maxThreads: int
    stopFlag: bool
    # Select
    timers: HeapQueue[tuple[finishAt: MonoTime, ioOperationPtr: ptr IoOperation]]
    selectorFd: FileHandle
    isWaiting: Atomic[bool]
    wakeUpEvent: UserEvent
    # Interactions
    readPoll: FdPolling
    writePoll: FdPolling
    completed: Channel[ptr IoOperation]
    cancelledCountStillInside: Atomic[int]


const MaxEpollEvents = 64
var GlobalIoCompletion: ptr IoCompletionPool


proc setGlobalIoCompletion(maxThreads = getMaxThreads())
setGlobalIoCompletion()


proc toEpollEvent(events: set[Event]): uint32 =
  result = EPOLLET# or EPOLLRDHUP
  if Event.Read in events:
    result = result or EPOLLIN
  if Event.Write in events:
    result = result or EPOLLOUT

proc registerHandle*(fd: AsyncFd, events: set[Event]) =
  var epv = EpollEvent(events: toEpollEvent(events), data: EpollData(fd: fd.cint))
  if epoll_ctl(GlobalIoCompletion[].selectorFd, EPOLL_CTL_ADD, epv.data.fd, addr epv) != 0:
    raiseOsError(osLastError())
  if events.card > 0 and events != { Event.Write }:
    GlobalIoCompletion[].readPoll.addFd(FileHandle(fd))
  if Event.Write in events:
    GlobalIoCompletion[].writePoll.addFd(FileHandle(fd))

proc unregister*(fd: AsyncFd) =
  discard

proc registerEvent*(userEvent: UserEvent) =
  var epv = EpollEvent(events: EPOLLET or EPOLLIN or EPOLLOUT, data: EpollData(fd: userEvent.fd.cint))
  if epoll_ctl(GlobalIoCompletion[].selectorFd, EPOLL_CTL_ADD, epv.data.fd, addr epv) != 0:
    raiseOsError(osLastError())

proc setGlobalIoCompletion(maxThreads = getMaxThreads()) =
  var completedChan: Channel[ptr IoOperation]
  open(completedChan)
  let wakeUpEvent = newUserEvent()
  GlobalIoCompletion = cast[ptr IoCompletionPool](allocShared(sizeof IoCompletionPool))
  GlobalIoCompletion[] = IoCompletionPool(
    maxThreads: maxThreads,
    selectorFd: epoll_create1(0),
    wakeUpEvent: wakeUpEvent,
    readPoll: initFdPolling(),
    writePoll: initFdPolling(),
    completed: completedChan
    )
  registerEvent(GlobalIoCompletion[].wakeUpEvent)

proc destroyGlobalIoCompletion*() =
  if close(GlobalIoCompletion[].selectorFd) == -1:
    raiseOsError(osLastError()) 
  close(GlobalIoCompletion[].wakeUpEvent)
  deinit(GlobalIoCompletion[].readPoll)
  deinit(GlobalIoCompletion[].writePoll)
  close(GlobalIoCompletion[].completed)
  dealloc(GlobalIoCompletion)

proc poll(timeoutMs: int): bool =
  ## return true if there are new pending fd
  var readyFdList: array[MaxEpollEvents, EpollEvent]
  if timeoutMs == -1:
    GlobalIoCompletion[].isWaiting.store(true)
  let count = epoll_wait(GlobalIoCompletion[].selectorFd, addr readyFdList[0], MaxEpollEvents, timeoutMs.cint)
  if timeoutMs == -1:
    GlobalIoCompletion[].isWaiting.store(false)
  if count == -1:
    raiseOsError(osLastError())
  for i in 0..<count:
    let readyKey = readyFdList[i]
    if readyKey.data.fd == GlobalIoCompletion[].wakeUpEvent.fd:
      continue
    let readyKeyEvents = readyKey.events.int
    if (readyKeyEvents and EPOLLERR) != 0:
      raiseOsError(osLastError()) # TODO: https://github.com/nim-lang/Nim/blob/646bd99d461469f08e656f92ae278d6695b35778/lib/pure/ioselects/ioselectors_epoll.nim#L400
    if (readyKeyEvents and EPOLLIN) != 0:
      result = result or setFdAsReady(GlobalIoCompletion[].readPoll, readyKey.data.fd)
    if (readyKeyEvents and EPOLLOUT) != 0:
      result = result or setFdAsReady(GlobalIoCompletion[].writePoll, readyKey.data.fd)


#[ *** Loop *** ]#

proc processTimers(): int =
  if GlobalIoCompletion[].timers.len() == 0:
    return -1
  let monoTimeNow = getMonoTime()
  while GlobalIoCompletion[].timers[0].finishAt < monoTimeNow:
    let ioOperationPtr = GlobalIoCompletion[].timers.pop().ioOperationPtr
    GlobalIoCompletion[].completed.send(ioOperationPtr)
    if GlobalIoCompletion[].timers.len() == 0:
      return -1
  return (GlobalIoCompletion[].timers[0].finishAt - monoTimeNow).inMilliseconds()

proc processIoOperation() =
  var exhaustedFd = false
  for (fd, ioOpPtr) in pendingItems(GlobalIoCompletion[].readPoll, exhaustedFd):
    read(fd, ioOpPtr, exhaustedFd)
    GlobalIoCompletion[].completed.send(ioOpPtr)
  for (fd, ioOpPtr) in pendingItems(GlobalIoCompletion[].writePoll, exhaustedFd):
    write(fd, ioOpPtr, exhaustedFd)
    GlobalIoCompletion[].completed.send(ioOpPtr)


proc masterLoop() {.thread.} =
  while not GlobalIoCompletion[].stopFlag:
    let selectorTimeout = processTimers()
    discard poll(selectorTimeout)
    processIoOperation()

proc getNextCompletedIoOperation*(): ptr IoOperation =
  GlobalIoCompletion[].completed.recv()

#[ *** AsyncIo *** ]#

proc readFileAsync*(fd: AsyncFd, buffer: pointer, size: int, ioOpPtr: ptr IOOperation) =
  ioOpPtr[].kind = Event.Read
  ioOpPtr[].isFile = true
  ioOpPtr[].buffer = buffer
  ioOpPtr[].bytesRequested = size
  if addIoOperation(GlobalIoCompletion[].readPoll, FileHandle(fd), ioOpPtr) and 
        GlobalIoCompletion[].isWaiting.load():
    GlobalIoCompletion[].wakeUpEvent.trigger()
