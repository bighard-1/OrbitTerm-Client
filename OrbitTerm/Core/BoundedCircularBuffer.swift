import Foundation

/// Fixed-capacity chronological storage used by monitor histories. Appending
/// after capacity is reached replaces the oldest point without growing memory.
struct BoundedCircularBuffer<Element> {
    private var storage: [Element] = []
    private var cursor = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
            return
        }

        storage[cursor] = element
        cursor = (cursor + 1) % capacity
    }

    var elementsInOrder: [Element] {
        guard storage.count == capacity else { return storage }
        return Array(storage[cursor...]) + Array(storage[..<cursor])
    }
}
