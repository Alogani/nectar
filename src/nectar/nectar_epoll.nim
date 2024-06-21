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
    lock: Lock
    registeredReadHandles: Table[FileHandle, Channel[ptr IoOperation]]
    registeredWriteHandles: Table[FileHandle, Channel[ptr IoOperation]]
    readReadyList: HashSet[FileHandle]
    writeReadyList: HashSet[FileHandle]
    completed: Channel[ptr IoOperation]


const MaxEpollEvents = 64
var GlobalIoCompletion: ptr IoCompletionPool


proc setGlobalIoCompletion(maxThreads = getMaxThreads())
setGlobalIoCompletion()


proc toEpollEvent(events: set[Event]): uint32 =
  result = EPOLLET or EPOLLRDHUP
  if Event.Read in events:
    result = result or EPOLLIN
  if Event.Write in events:
    result = result or EPOLLOUT


proc registerHandle(fd: AsyncFd, events: set[Event]) =
  var epv = EpollEvent(events: toEpollEvent(events))
  if epoll_ctl(GlobalIoCompletion[].selectorFd, EPOLL_CTL_ADD, fd.cint, addr epv) != 0:
    raiseOsError(osLastError())

proc registerEvent(userEvent: UserEvent) =
  var epv = EpollEvent(events: EPOLLET or EPOLLIN or EPOLLOUT)
  if epoll_ctl(GlobalIoCompletion[].selectorFd, EPOLL_CTL_ADD, userEvent.fd.cint, addr epv) != 0:
    raiseOsError(osLastError())

proc setGlobalIoCompletion(maxThreads = getMaxThreads()) =
  var lock: Lock
  initLock(lock)
  var completedChan: Channel[ptr IoOperation]
  open(completedChan)
  let wakeUpEvent = newUserEvent()
  GlobalIoCompletion = cast[ptr IoCompletionPool](allocShared(sizeof IoCompletionPool))
  GlobalIoCompletion[] = IoCompletionPool(
    maxThreads: maxThreads,
    selectorFd: epoll_create1(0),
    wakeUpEvent: wakeUpEvent,
    lock: lock,
    completed: completedChan
    )
  registerEvent(wakeUpEvent)

proc poll(timeoutMs: int): int =
  var epvTable: array[MaxEpollEvents, EpollEvent]
  let count = epoll_wait(GlobalIoCompletion[].selectorFd, addr epvTable[0], MaxEpollEvents, timeoutMs.cint)
  if count == -1:
    raiseOsError(osLastError())
  for epv in epvTable:
    let epvEvents = epv.events.int
    if (epvEvents and EPOLLERR) != 0:
      raiseOsError(osLastError()) # TODO: https://github.com/nim-lang/Nim/blob/646bd99d461469f08e656f92ae278d6695b35778/lib/pure/ioselects/ioselectors_epoll.nim#L400
    if (epvEvents and EPOLLIN) != 0:
      GlobalIoCompletion[].readReadyList.incl(epv.data.fd)
    if (epvEvents and EPOLLOUT) != 0:
      GlobalIoCompletion[].writeReadyList.incl(epv.data.fd)
  return count


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


proc masterLoop() {.thread.} =
  while not GlobalIoCompletion[].stopFlag:
    let selectorTimeout = processTimers()
    let readyCount = poll(selectorTimeout)
