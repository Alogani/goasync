## Stackful asymmetric coroutines implementation, inspired freely from some language and relying on minicoro c library.
## Lighweight and efficient thanks to direct asm code and optional support for virtual memory.
## Push, pop and return value were not implemented, because type and GC safety cannot be guaranted, especially in multithreaded environment. Use CoChannels instead

#[ ********* minicoroutines.h v0.2.0 wrapper ********* ]#
# Choice has been made to rely on minicoroutines for numerous reasons (efficient, single file, clear API, cross platform, virtual memory, etc.)
# Inspired freely from https://git.envs.net/iacore/minicoro-nim

when not defined(gcArc) and not defined(gcOrc):
    {.warning: "coroutines is not tested without --mm:orc or --mm:arc".}

from std/os import parentDir, `/` 
const minicoroh = currentSourcePath().parentdir() / "private/minicoro.h"
    
{.compile: "./private/minicoro.c".}
when defined(coroUseVMem):
    {.passC: "-DMCO_USE_VMEM_ALLOCATOR".}
when not defined(debug):
    {.passC: "-DMCO_NO_DEBUG".}


when defined(coroUseVMem):
    const DefaultStackSize = 2040 * 1024 ## Recommanded by MCO
else:
    const DefaultStackSize = 56 * 1024 ## Recommanded by MCO

type
    McoCoroDescriptor {.importc: "mco_desc", header: minicoroh.} = object
        ## Contains various propery used to init a coroutine
        entryFn: pointer
        user_data*: pointer ## Only this one is useful to us
        alloc_cb: pointer
        dealloc_cb: pointer
        allocator_data: pointer
        storage_size: uint
        coro_size: uint
        stack_size: uint

    McoReturnCode {.pure, importc: "mco_result", header: minicoroh.} = enum
        Success = 0,
        GenericError,
        InvalidPointer,
        InvalidCoroutine,
        NotSuspended,
        NotRunning,
        Makecontext_Error,
        Switchcontext_Error,
        NotEnoughSpace,
        OutOfMemory,
        InvalidArguments,
        InvalidOperation,
        StackOverflow,

    CoroutineError* = object of OSError

    McoCoroState {.importc: "mco_state", header: minicoroh.} = enum
        # The original name were renamed for clarity
        McoCsFinished = 0, ## /* The coroutine has finished normally or was uninitialized before finishing. */
        McoCsParenting, ## /* The coroutine is active but not running (that is, it has resumed another coroutine). */
        McoCsRunning, ## /* The coroutine is active and running. */
        McoCsSuspended ## /* The coroutine is suspended (in a call to yield, or it has not started running yet). */

    McoCoroutine {.importc: "mco_coro", header: minicoroh.} = object
        ## Internals we don't touch
        context: pointer
        mco_state: McoCoroState
        prev_co: pointer
        user_data: pointer
        coro_size: uint
        allocator_data: pointer
        alloc_cb: pointer
        dealloc_cb: pointer
        stack_base: pointer
        stack_size: cint
        storage: pointer
        bytes_stored: uint
        storage_size: uint
        asan_prev_stack: pointer
        tsan_prev_fiber: pointer
        tsan_fiber: pointer
        magic_number: uint

    cstring_const* {.importc:"const char*", header: minicoroh.} = cstring

proc initMcoDescriptor(entryFn: proc (coro: ptr McoCoroutine) {.cdecl.}, stackSize: uint): McoCoroDescriptor {.importc: "mco_desc_init", header: minicoroh.}
proc uninitMcoCoroutine(coro: ptr McoCoroutine): McoReturnCode {.importc: "mco_uninit", header: minicoroh.}
proc createMcoCoroutine(outCoro: ptr ptr McoCoroutine, descriptor: ptr McoCoroDescriptor): McoReturnCode {.importc: "mco_create", header: minicoroh.}
proc destroyMco(coro: ptr McoCoroutine): McoReturnCode {.importc: "mco_destroy", header: minicoroh.}
proc resume(coro: ptr McoCoroutine): McoReturnCode {.importc: "mco_resume", header: minicoroh.}
proc suspend(coro: ptr McoCoroutine): McoReturnCode {.importc: "mco_yield", header: minicoroh.}
proc getState(coro: ptr McoCoroutine): McoCoroState {.importc: "mco_status", header: minicoroh.}
proc getUserData(coro: ptr McoCoroutine): pointer {.importc: "mco_get_user_data", header: minicoroh.}
proc getRunningMco(): ptr McoCoroutine {.importc: "mco_running", header: minicoroh.}
proc prettyError(returnCode: McoReturnCode): cstring_const {.importc: "mco_result_description", header: minicoroh.}

proc checkMcoReturnCode(returnCode: McoReturnCode) =
    if returnCode != Success:
        raise newException(CoroutineError, $returnCode.prettyError())


#[ ********* API ********* ]#

import ./private/smartptrs

type
    CoroState* = enum
        CsRunning ## Is the current main coroutine
        CsParenting ## The coroutine is active but not running (that is, it has resumed another coroutine).
        CsSuspended
        CsFinished
        CsDead ## Finished with an error
    
    EntryFn = proc()
        ## Supports at least closure and nimcall calling convention

    CoroutineObj = object
        entryFn: EntryFn
        mcoCoroutine: ptr McoCoroutine
        exception: ptr Exception

    Coroutine* = SharedPtr[CoroutineObj]
        ## Basic coroutine object
        ## Thread safety: unstarted coroutine can be moved between threads
        ## Moving started coroutine, using resume/suspend are completely thread unsafe in ORC (and maybe ARC too)

proc coroutineMain(mcoCoroutine: ptr McoCoroutine) {.cdecl.} =
    ## Start point of the coroutine.
    let coroPtr = cast[ptr CoroutineObj](mcoCoroutine.getUserData())
    try:
        coroPtr.entryFn()
    except:
        let exception = getCurrentException()
        Gc_ref exception
        coroPtr.exception = cast[ptr Exception](exception)

proc destroyMoCoroutine(coroObj: CoroutineObj) =
    checkMcoReturnCode uninitMcoCoroutine(coroObj.mcoCoroutine)
    checkMcoReturnCode destroyMco(coroObj.mcoCoroutine)

proc `=destroy`*(coroObj: CoroutineObj) =
    ## Allow to destroy an unfinished coroutine (finished coroutine autoclean themselves).
    ## Don't works on running coroutine
    ## It is better to avoid destroy and resume the coroutine until the end to avoid GC
    if coroObj.mcoCoroutine != nil:
        try:
            destroyMoCoroutine(coroObj)
        except:
            discard
    if coroObj.exception != nil:
        dealloc(coroObj.exception)

proc new*(OT: type Coroutine, entryFn: EntryFn, stacksize = DefaultStackSize): Coroutine =
    result = newSharedPtr(CoroutineObj(entryFn: entryFn))
    var mcoCoroDescriptor = initMcoDescriptor(coroutineMain, stacksize.uint)
    mcoCoroDescriptor.user_data = result.getUnsafePtr()
    checkMcoReturnCode createMcoCoroutine(addr(result[].mcoCoroutine), addr mcoCoroDescriptor)

proc resume*(coro: Coroutine) =
    ## Will resume the coroutine where it stopped (or start it).
    ## Will do nothing if coroutine is finished
    if getState(coro[].mcoCoroutine) == McoCsFinished:
        return
    let frame = getFrameState()
    checkMcoReturnCode resume(coro[].mcoCoroutine)
    setFrameState(frame)

proc suspend*() =
    ## Suspend the actual running coroutine
    let frame = getFrameState()
    checkMcoReturnCode suspend(getRunningMco())
    setFrameState(frame)

proc suspend*(coro: Coroutine) =
    ## Optimization to avoid calling getRunningMco() twice which has some overhead
    ## Never use if coro is different than current coroutine
    let frame = getFrameState()
    checkMcoReturnCode suspend(coro[].mcoCoroutine)
    setFrameState(frame)

proc getCurrentCoroutine*(): Coroutine =
    ## Get the actual running coroutine
    ## If we are not inside a coroutine, nil is retuned
    return toSharedPtr(CoroutineObj, getRunningMco().getUserData())

proc getException*(coro: Coroutine): ref Exception =
    ## nil if state is different than CsDead
    result = cast[ref Exception](coro[].exception)
    Gc_unref(result)

proc getState*(coro: Coroutine): CoroState =
    case coro[].mcoCoroutine.getState():
    of McoCsFinished:
        if coro[].exception == nil:
            CsFinished
        else:
            CsDead
    of McoCsParenting:
        CsParenting
    of McoCsRunning:
        CsRunning
    of McoCsSuspended:
        CsSuspended
