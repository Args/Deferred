//
//  Deferred.swift
//  AsyncNetworkServer
//
//  Created by John Gallagher on 7/19/14.
//  Copyright (c) 2014 Big Nerd Ranch. All rights reserved.
//

import Foundation

// TODO: Replace this with a class var
@available(OSX 10.10, *)
public var DeferredDefaultQueue = DispatchQueue.global(qos: DispatchQoS.default.qosClass)

open class Deferred<T> {
    typealias UponBlock = (DispatchQueue, (T) -> ())
    fileprivate typealias Protected = (protectedValue: T?, uponBlocks: [UponBlock])

    fileprivate var protected: LockProtected<Protected>
    fileprivate let defaultQueue: DispatchQueue

    @available(OSX 10.10, *)
    public init(value: T? = nil, defaultQueue: DispatchQueue = DeferredDefaultQueue) {
        protected = LockProtected(item: (value, []))
        self.defaultQueue = defaultQueue
    }

    // Check whether or not the receiver is filled
    open var isFilled: Bool {
        return protected.withReadLock { $0.protectedValue != nil }
    }

    fileprivate func _fill(_ value: T, assertIfFilled: Bool) {
        let (filledValue, blocks) = protected.withWriteLock { data -> (T, [UponBlock]) in
            if assertIfFilled {
                precondition(data.protectedValue == nil, "Cannot fill an already-filled Deferred")
                data.protectedValue = value
            } else if data.protectedValue == nil {
                data.protectedValue = value
            }
            let blocks = data.uponBlocks
            data.uponBlocks.removeAll(keepingCapacity: false)
            return (data.protectedValue!, blocks)
        }
        for (queue, block) in blocks {
            queue.async { block(filledValue) }
        }
    }

    open func fill(_ value: T) {
        _fill(value, assertIfFilled: true)
    }

    open func fillIfUnfilled(_ value: T) {
        _fill(value, assertIfFilled: false)
    }

    open func peek() -> T? {
        return protected.withReadLock { $0.protectedValue }
    }

    open func uponQueue(_ queue: DispatchQueue, block: @escaping (T) -> ()) {
        let maybeValue: T? = protected.withWriteLock{ data in
            if data.protectedValue == nil {
                data.uponBlocks.append( (queue, block) )
            }
            return data.protectedValue
        }
        if let value = maybeValue {
            queue.async { block(value) }
        }
    }
}

extension Deferred {
    public var value: T {
        // fast path - return if already filled
        if let v = peek() {
            return v
        }

        // slow path - block until filled
        let group = DispatchGroup()
        var result: T!
        group.enter()
        self.upon { result = $0; group.leave() }
        let _ = group.wait(timeout: DispatchTime.distantFuture)
        return result
    }
}

extension Deferred {
     @available(OSX 10.10, *)
    public func bindQueue<U>(_ queue: DispatchQueue, f: @escaping (T) -> Deferred<U>) -> Deferred<U> {
        let d = Deferred<U>()
        self.uponQueue(queue) {
            f($0).uponQueue(queue) {
                d.fill($0)
            }
        }
        return d
    }

    @available(OSX 10.10, *)
    public func mapQueue<U>(_ queue: DispatchQueue, f: @escaping (T) -> U) -> Deferred<U> {
        return bindQueue(queue) { t in Deferred<U>(value: f(t)) }
    }
}

extension Deferred {
    public func upon(_ block: @escaping (T) ->()) {
        uponQueue(defaultQueue, block: block)
    }

    @available(OSX 10.10, *)
    public func bind<U>(_ f: @escaping (T) -> Deferred<U>) -> Deferred<U> {
        return bindQueue(defaultQueue, f: f)
    }

    @available(OSX 10.10, *)
    public func map<U>(_ f: @escaping (T) -> U) -> Deferred<U> {
        return mapQueue(defaultQueue, f: f)
    }
}

extension Deferred {
    @available(OSX 10.10, *)
    public func both<U>(_ other: Deferred<U>) -> Deferred<(T,U)> {
        return self.bind { t in other.map { u in (t, u) } }
    }
}

@available(OSX 10.10, *)
public func all<T>(_ deferreds: [Deferred<T>]) -> Deferred<[T]> {
    if deferreds.count == 0 {
        return Deferred(value: [])
    }

    let combined = Deferred<[T]>()
    var results: [T] = []
    results.reserveCapacity(deferreds.count)

    var block: ((T) -> ())!
    block = { t in
        results.append(t)
        if results.count == deferreds.count {
            combined.fill(results)
        } else {
            deferreds[results.count].upon(block)
        }
    }
    deferreds[0].upon(block)

    return combined
}

@available(OSX 10.10, *)
public func any<T>(_ deferreds: [Deferred<T>]) -> Deferred<Deferred<T>> {
    let combined = Deferred<Deferred<T>>()
    for d in deferreds {
        d.upon { _ in combined.fillIfUnfilled(d) }
    }
    return combined
}
