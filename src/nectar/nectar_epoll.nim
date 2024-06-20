import std/epoll

const includeUnixCommons {.used.} = true
include ./unixcommons

#[ *** compile flags *** ]#

const IoPoolSize* {.intdefine.} = 0

type
  Selector = object
    epollFd: FileHandle
    wakeUpEvent: UserEvent
    lock: Lock
    isWaiting: Atomic[bool]
    registeredReadHandles: Table[FileHandle, Channel[ptr IoOperation]]
    registeredWriteHandles: Table[FileHandle, Channel[ptr IoOperation]]
    readReadyList: HashSet[FileHandle]
    writeReadyList: HashSet[FileHandle]

  IoCompletionPoolObj = object
    selfThread: Thread[void]
    selector: Selector
    stopFlag: bool
  IoCompletionPool* = ptr IoCompletionPoolObj

const MaxEpollEvents = 64

proc toEpollEvent(events: set[Event]): uint32 =
  result = EPOLLET or EPOLLRDHUP
  if Event.Read in events:
    result = result or EPOLLIN
  if Event.Write in events:
    result = result or EPOLLOUT







proc registerHandle(selector: var Selector, fd: AsyncFd, events: set[Event]) =
  var epv = EpollEvent(events: toEpollEvent(events))
  if epoll_ctl(selector.epollFd, EPOLL_CTL_ADD, fd.cint, addr epv) != 0:
    raiseOsError(osLastError())

proc registerEvent(selector: var Selector, userEvent: UserEvent) =
  var epv = EpollEvent(events: EPOLLET or EPOLLIN or EPOLLOUT)
  if epoll_ctl(selector.epollFd, EPOLL_CTL_ADD, userEvent.fd.cint, addr epv) != 0:
    raiseOsError(osLastError())

proc newSelector(): Selector =
  var lock: Lock
  initLock(lock)
  result = Selector(
    epollFd: epoll_create1(0),
    wakeUpEvent: newUserEvent(),
    lock: lock
    )
  registerEvent(result, result.wakeUpEvent)

proc select(selector: var Selector, timeoutMs: int): int =
  var epvTable: array[MaxEpollEvents, EpollEvent]
  let count = epoll_wait(selector.epollFd, addr epvTable[0], MaxEpollEvents, timeoutMs.cint)
  if count == -1:
    raiseOsError(osLastError())
  for epv in epvTable:
    let epvEvents = epv.events.int
    if (epvEvents and EPOLLERR) != 0:
      raiseOsError(osLastError()) # TODO: https://github.com/nim-lang/Nim/blob/646bd99d461469f08e656f92ae278d6695b35778/lib/pure/ioselects/ioselectors_epoll.nim#L400
    if (epvEvents and EPOLLIN) != 0:
      selector.readReadyList.incl(epv.data.fd)
    if (epvEvents and EPOLLOUT) != 0:
      selector.writeReadyList.incl(epv.data.fd)
  return count




