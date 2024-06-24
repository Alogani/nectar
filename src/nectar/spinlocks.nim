import std/atomics

type
  SpinLock* = Atomic[bool]
    ## Slower than std/locks when waiting is done, so only try API is provided

proc tryAcquire*(lock: var SpinLock): bool =
  var expected = false
  if compareExchange(lock, expected, true):
    return true
  return false

proc release*(lock: var SpinLock) =
  lock.store(false)
  