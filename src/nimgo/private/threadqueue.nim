import std/[options]
import ./[atomics, smartptrs]

export options

## Lock free (thread safe) queue implementation using linked list
## Constant complexity with minimal overhead even if push/pop are not balanced

type
    Node[T] = object
        val: T
        next: Atomic[ptr Node[T]]

    ThreadQueueObj[T] = object
        head: Atomic[ptr Node[T]]
        tail: Atomic[ptr Node[T]]

    ThreadQueue*[T] = SharedPtr[ThreadQueueObj[T]]


proc newThreadQueue*[T](): ThreadQueue[T] =
    let node = cast[ptr Node[T]](allocShared(sizeof Node[T]))
    let atomicNode = newAtomic(node)
    return newSharedPtr(ThreadQueueObj[T](
        head: atomicNode,
        tail: atomicNode
    ))

proc `=destroy`*[T](q: ThreadQueueObj[T]) {.nodestroy.} =
    var q = q # Needs a var
    var currentNode = q.head.load(moRelaxed)
    while currentNode != nil:
        let nextNode = currentNode.next.load(moRelaxed)
        dealloc(currentNode)
        currentNode = nextNode

proc pushLast*[T](q: ThreadQueue[T], val: sink T) =
    let newNode = cast[ptr Node[T]](allocShared(sizeof Node[T]))
    when defined(gcOrc):
        GC_runOrc()
    when T is ref:
        Gc_ref(val)
    newNode[] = Node[T](val: val)
    let prevTail = q[].tail.exchange(newNode, moAcquireRelease)
    prevTail[].next.store(newNode, moRelease)

proc popFirst*[T](q: ThreadQueue[T]): Option[T] =
    var oldHead = q[].head.load(moAcquire)
    let newHead = oldHead[].next.load(moAcquire)
    if newHead == nil:
        return none(T)
    if q[].head.compareExchange(oldHead, newHead, moAcquireRelease):
        result = some(move(newHead[].val))
        when T is ref:
            Gc_unref(val)
        dealloc(oldHead)
        return

proc empty*[T](q: ThreadQueue[T]): bool =
    ## The atomicity cannot be guaranted
    return q[].head.load(moAcquire) == q[].tail.load(moAcquire)

    