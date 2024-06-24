when not declared(includeUnixCommons):
  {.push used.}
  {.warning[UnusedImport]: false.}

import std/[posix, oserrors]
import std/[sets, tables, heapqueue, monotimes, times]
import std/[atomics, locks]
import std/cpuinfo

import ./[rwlocks, spinlocks]

const IoPoolSize* {.intdefine.} = 0


proc getMaxThreads(): int =
  if IoPoolSize > 0:
    return IoPoolSize
  else:
    return countProcessors()


iterator items*[T](chan: var Channel[T]): T =
  while true:
    let tried = chan.tryRecv()
    if tried.dataAvailable:
      yield tried.msg
    break


type
  AsyncFd = distinct FileHandle

  Event {.pure.} = enum
    Read, Write

proc newAsyncFd(fd: FileHandle): AsyncFd =
  ## AsyncFd will become non blocking
  if fcntl(fd, F_SETFD, O_NONBLOCK) == -1:
    raiseOsError(osLastError())
  return AsyncFd(fd)

proc closeAsyncFd(fd: AsyncFd) =
  if close(fd.cint) == -1:
    raiseOsError(osLastError())


type
  UserEvent = object
    # Event in unix can be read/write and act as a semaphore
    # We simplify that usage to save a syscall by using indefferently one or the other
    fd: cint
    current: Event

proc eventfd(count: cuint, flags: cint): cint
     {.cdecl, importc: "eventfd", header: "<sys/eventfd.h>".}


proc `=copy`*(dest: var UserEvent, src: UserEvent) {.error.}

proc newUserEvent*(): UserEvent =
  let fd = eventfd(0, O_CLOEXEC or O_NONBLOCK)
  if fd == -1:
    raiseOsError(osLastError())
  UserEvent(fd: fd, current: Event.Write)

proc close*(userEvent: UserEvent) =
  if close(userEvent.fd) == -1:
    raiseOsError(osLastError())

proc trigger*(userEvent: var UserEvent) =
  ## It is a one shot, so can be triggered multiple times (small risk of data race)
  var data = 1'u64
  if userEvent.current == Event.Read:
    if read(userEvent.fd, addr data, sizeof(uint64)) == -1:
      raiseOsError(osLastError())
  else:
    if write(userEvent.fd, addr data, sizeof(uint64)) == -1:
      raiseOsError(osLastError())

proc getOsFileHandle*(userEvent: UserEvent): FileHandle =
  userEvent.fd


type
  IoOperation* = object
    userData: pointer
    kind: Event
    isFile: bool
    buffer: pointer
    bytesRequested: int
    bytesTransfered: int

  FdPolling = object
    pending: Channel[FileHandle] # Ready with pending Io
    ready: HashSet[FileHandle] # Ready with no pending Io
    readyLock: Lock
    fdMap: Table[FileHandle, Channel[ptr IoOperation]]
    fdMapRwLock: RwLock


proc initIoOperation*(userData: pointer): IoOperation =
  return IoOperation(userData: userData)

proc getInfo*(ioOpPtr: ptr IoOperation): tuple[userData: pointer, bytesTransfered: int] =
  return (
    ioOpPtr[].userData,
    ioOpPtr[].bytesTransfered,
  )

proc initFdPolling(): FdPolling =
  var pending: Channel[FileHandle]
  var readyLock: Lock
  var fdMapRwLock: Rwlock
  initLock(readyLock)
  initLock(fdMapRwLock)
  open(pending)
  return FdPolling(
    pending: pending,
    readyLock: readyLock,
    fdMapRwLock: fdMapRwLock
  )

proc deinit(fdPoll: var FdPolling) =
  close(fdPoll.pending)
  deinitLock(fdPoll.readyLock)
  deinitLock(fdPoll.fdMapRwLock)

proc setFdAsReady(fdPoll: var FdPolling, fd: FileHandle): bool =
  ## Not data race safe
  ## Return true if fd has pending operations
  ## Don't wake up selector
  withReadLock(fdPoll.fdMapRwLock):
    if fdPoll.fdMap[fd].peek != 0:
      fdPoll.pending.send(fd)
      return true
    else:
      withLock(fdPoll.readyLock):
        fdPoll.ready.incl(fd)
      return false

proc addFd(fdPoll: var FdPolling, fd: FileHandle) =
  ## Not data race safe
  var chan: Channel[ptr IoOperation]
  open(chan)
  withWriteLock(fdPoll.fdMapRwLock):
    assert fd notin fdPoll.fdMap
    fdPoll.fdMap[fd] = chan

proc removeFd(fdPoll: var FdPolling, fd: FileHandle) =
  ## Not data race safe
  var chan: Channel[ptr IoOperation]
  withWriteLock(fdPoll.fdMapRwLock):
    doAssert fdPoll.fdMap.pop(fd, chan)
  chan.close()
  
proc addIoOperation(fdPoll: var FdPolling, fd: FileHandle, ioOpPtr: ptr IoOperation): bool =
  ## Data race safe
  ## Return true if fd is moved from ready to pending
  withReadLock(fdPoll.fdMapRwLock):
    fdPoll.fdMap[fd].send(ioOpPtr)
  withLock(fdPoll.readyLock):
    if fd in fdPoll.ready:
      result = true
      fdPoll.pending.send(fd)
      fdPoll.ready.excl(fd)

iterator pendingItems(fdPoll: var FdPolling, exhaustedFd: bool): (FileHandle, ptr IoOperation) =
  ## Data race safe
  for pendingFd in fdPoll.pending:
    withReadLock(fdPoll.fdMapRwLock):
      if pendingFd in fdPoll.fdMap:
        for ioOpPtr in fdPoll.fdMap[pendingFd]:
          yield (pendingFd, ioOpPtr)
          if exhaustedFd:
            break
    if not exhaustedFd:
      withLock(fdPoll.readyLock):
        fdPoll.ready.incl(pendingFd)

proc read(fd: FileHandle, ioOpPtr: ptr IoOperation, exhaustedFd: var bool) =
  let bytesRequested = ioOpPtr[].bytesRequested
  let bytesCount = read(fd, ioOpPtr[].buffer, bytesRequested)
  ioOpPtr[].bytesTransfered = bytesCount
  if bytesCount == -1:
    let errCode = osLastError()
    if errCode.cint == EAGAIN:
      exhaustedFd = true
    else:
      raiseOSError(errCode)
  if bytesCount < bytesRequested and ioOpPtr[].isFile:
    exhaustedFd = true

proc write(fd: FileHandle, ioOpPtr: ptr IoOperation, exhaustedFd: var bool) =
  discard
