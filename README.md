# zig-lfu
This repository contains an implementation of a Constant Time O(1) Least Frequently Used cache, created as a learning exercise. In LFU caches, items are held up to a certain capacity. When that capacity is reached, any new items will cause the eviction of one of the least frequently used items in memory. This particular implementation, inspired by the article at https://arpitbhayani.me/blogs/lfu, provides constant time for all three main operations: `put`, `get` and `evict`. This constant time comes at the expense of increased memory usage over other alternative approaches, as this LFU requires one hashmap and a special double linked list for function.

## Requirements
 - Zig v0.6

## Usage
In this example we will create a LFU cache with a capacity of 3 items. When we add the fourth one, the least used is discarded to make room.
```zig
// Note that you must provide an allocator to the structure
var lfu = AutoLFU(i32, []const u8).init(allocator, 5);
defer lfu.deinit();

// By default, only `get` operations increase the usage count. However, we can configure that by changing the following settings
lfu.increment_on_put = true;
lfu.increment_on_get = true;

// Since `put` might allocate memory (and thus can fail), we must be handle such situations.
// In this case, we simply use `try` for that
try lfu.put(1, "One");

// It might seem counter-intuitive that get, a read operation, can fail as well
// However, since getting a value increases it's usage count, that requires potential 
// memory allocation. In reality, this implementation tries to avoid allocations as much
// as possible by reusing existing memory, which means most get operations do not allocate memory
if (try lfu.get(1)) |cached_value| {
    std.debug.print("The value is {}\n", .{cached_value});
}

// If for some reason a value needs to be manually removed from the cache, we can
// call the `evict` method. It returns the value that was stored in there (if any)
// so that memory management actions can be taken, if necessary
_ = lfu.evict(1);

// Or if the contents were heap allocated
if (lfu.evict(1)) |str_ptr| {
    allocator.free(str_ptr);
}
```

## Running the tests
To run the tests, just execute the following command:
```bash
zig test src/lfu.zig
```