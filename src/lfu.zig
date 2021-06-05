const std = @import("std");
const Allocator = std.mem.Allocator;
const fieldInfo = std.meta.fieldInfo;

const AutoContext = std.hash_map.AutoContext;
const StringContext = std.hash_map.StringContext;
const getAutoHashFn = std.hash_map.getAutoHashFn;
const getAutoEqlFn = std.hash_map.getAutoEqlFn;

pub fn AutoLFU(comptime K: type, comptime V: type) type {
    return LFU(K, V, AutoContext(K));
}

pub fn StringLFU(comptime V: type) type {
    return LFU([]const u8, V, StringContext);
}

pub fn LFU(
    comptime K: type,
    comptime V: type,
    comptime Context: anytype,
) type {
    return struct {
        allocator: *Allocator,
        hashmap: ItemsHashMap,
        buckets: BucketsLinkedList,
        capacity: u64,
        count: u64,

        increment_on_put: bool = false,
        increment_on_get: bool = true,

        const Self = @This();

        const ItemsHashMap = std.HashMap(K, *Item, Context, std.hash_map.DefaultMaxLoadPercentage);

        const ItemsLinkedList = std.TailQueue(struct {
            key: K,
            value: V,
            bucket: ?*Bucket,
        });

        const BucketsLinkedList = std.TailQueue(struct {
            uses: u32,
            items: ItemsLinkedList,
        });

        const Item = ItemsLinkedList.Node;
        const Bucket = BucketsLinkedList.Node;

        pub fn init(allocator: *Allocator, capacity: u32) Self {
            return .{
                .allocator = allocator,
                .hashmap = ItemsHashMap.init(allocator),
                .buckets = BucketsLinkedList{},
                .capacity = capacity,
                .count = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            self.hashmap.deinit();

            var bucket_cursor: ?*Bucket = self.buckets.first;
            var item_cursor: ?*Item = null;

            var next_bucket: ?*Bucket = null;
            var next_item: ?*Item = null;

            while (bucket_cursor) |bucket| : (bucket_cursor = next_bucket) {
                item_cursor = bucket.data.items.first;

                while (item_cursor) |item| : (item_cursor = next_item) {
                    next_item = item.next;
                    self.allocator.destroy(item);
                }

                next_bucket = bucket.next;
                self.allocator.destroy(bucket);
            }

            self.buckets.first = null;
            self.buckets.last = null;
            self.buckets.len = 0;

            self.count = 0;
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            if (self.hashmap.getEntry(key)) |entry| {
                entry.value_ptr.*.data.value = value;

                if (self.increment_on_put) {
                    try self.inc(entry.value_ptr.*);
                }
            } else {
                const uses: u32 = if (self.increment_on_put) 1 else 0;

                var item: *Item = try self.acquire(key, value);

                var bucket = try self.acquireBucketForItem(uses, null, item);

                item.data.bucket = bucket;

                bucket.data.items.append(item);

                try self.hashmap.putNoClobber(key, item);

                self.count += 1;
            }
        }

        pub fn get(self: *Self, key: K) !?V {
            var item: *Item = self.hashmap.get(key) orelse return null;

            if (self.increment_on_get) {
                try self.inc(item);
            }

            return item.data.value;
        }

        pub fn getUses(self: *Self, key: K) ?u32 {
            var item: *Item = self.hashmap.get(key) orelse return null;

            var bucket: *Bucket = item.data.bucket orelse return null;

            return bucket.data.uses;
        }

        pub fn acquireBucketForItem(self: *Self, uses: u32, startAt: ?*Bucket, item: *Item) !*Bucket {
            var it_bck = item.data.bucket;

            var should_reuse = it_bck != null and it_bck.?.data.items.first == null;

            var reusable_bucket = if (should_reuse) it_bck else null;

            var bucket = try self.acquireBucket(uses, startAt, reusable_bucket);

            if (bucket != reusable_bucket and reusable_bucket != null) {
                self.allocator.destroy(reusable_bucket.?);
            }

            return bucket;
        }

        pub fn acquireBucket(self: *Self, uses: u32, startAt: ?*Bucket, reused: ?*Bucket) !*Bucket {
            var cursor = startAt orelse self.buckets.first;

            var maybe_next: ?*Bucket = null;

            while (cursor) |bucket| : (cursor = bucket.next) {
                if (bucket.data.uses == uses) {
                    return bucket;
                } else if (bucket.data.uses > uses) {
                    maybe_next = bucket;
                    break;
                }
            }

            var new_bucket: *Bucket = reused orelse node: {
                var ptr = try self.allocator.create(Bucket);

                ptr.* = Bucket{
                    .data = .{
                        .uses = 0,
                        .items = ItemsLinkedList{},
                    },
                };

                break :node ptr;
            };

            new_bucket.data.uses = uses;

            if (maybe_next) |next| {
                self.buckets.insertBefore(next, new_bucket);
            } else {
                self.buckets.append(new_bucket);
            }

            return new_bucket;
        }

        pub fn acquire(self: *Self, key: K, value: V) !*Item {
            if (self.count >= self.capacity) {
                var bucket = self.buckets.first.?;

                var least_used = bucket.data.items.first.?;

                self.evictNode(least_used);

                least_used.* = Item{
                    .data = .{
                        .key = key,
                        .value = value,
                        // We should retain the old bucket so that it can be reused,
                        // if possible. Otherwise, the caller should free it, if empty
                        .bucket = least_used.data.bucket,
                    },
                };

                return least_used;
            }

            var ptr = try self.allocator.create(Item);

            ptr.* = Item{
                .data = .{
                    .key = key,
                    .value = value,
                    .bucket = null,
                },
            };

            return ptr;
        }

        pub fn inc(self: *Self, node: *Item) !void {
            std.debug.assert(node.data.bucket != null);

            var bucket: *Bucket = node.data.bucket.?;

            const new_usage = bucket.data.uses + 1;

            var maybe_next: ?*Bucket = bucket.next;

            self.detachNode(node);

            // Possible cases:
            //  1- there's a next bucket == new_usage:
            //      move to next bucket, and (potentially) free bucket
            //  2- there's a next bucket > new_usage and bucket != empty
            //      create new bucket after bucket
            //  3- there's a next bucket > new_usage and bucket == empty
            //      reuse bucket
            //  4- there's no next bucket and bucket != empty
            //      create new bucket after bucket
            //  5- there's no next bucket and bucket == empty
            //      reuse bucket
            const reuse = bucket.data.items.first == null;

            var new_bucket = try self.acquireBucket(new_usage, maybe_next, if (reuse) bucket else null);

            if (new_bucket == maybe_next and reuse) {
                self.allocator.destroy(bucket);
            }

            new_bucket.data.items.append(node);

            node.data.bucket = new_bucket;
        }

        pub fn evict(self: *Self, key: K) ?V {
            var item = self.hashmap.get(key) orelse return null;

            var value = item.data.value;

            self.evictNode(item);

            if (item.data.bucket) |item_bucket| {
                if (item_bucket.data.items.first == null) {
                    self.allocator.destroy(item_bucket);
                }
            }

            self.allocator.destroy(item);

            return value;
        }

        // The caller is responsible for freeing the memory that holds the node
        // And it's bucket too (if not empty)
        fn evictNode(self: *Self, node: *Item) void {
            _ = self.hashmap.remove(node.data.key);

            self.detachNode(node);

            self.count -= 1;
        }

        fn detachNode(self: *Self, node: *Item) void {
            var bucket: *Bucket = node.data.bucket orelse return;

            bucket.data.items.remove(node);

            if (bucket.data.items.first == null) {
                self.buckets.remove(bucket);
            }
        }
    };
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "Single cache item" {
    const BoolLFU = AutoLFU(i32, bool);

    var lfu = BoolLFU.init(std.testing.allocator, 5);
    defer lfu.deinit();

    try expect((try lfu.get(1)) == null);
    try lfu.put(1, true);
    try expect((try lfu.get(1)) == true);
    try expect((try lfu.get(1)) == true);
    try expect((try lfu.get(1)) == true);
    try expect(lfu.getUses(1).? == 3);
}

test "Overflow cache" {
    const IntLFU = AutoLFU(i32, i32);

    var lfu = IntLFU.init(std.testing.allocator, 5);
    defer lfu.deinit();

    try lfu.put(1, 10);
    try lfu.put(2, 20);
    try lfu.put(3, 30);
    try lfu.put(4, 40);
    try lfu.put(5, 50);

    // All keys except '3' should have usage == 2
    try expect((try lfu.get(1)).? == 10);
    try expect(lfu.getUses(1).? == 1);
    try expect((try lfu.get(1)).? == 10);
    try expect(lfu.getUses(1).? == 2);
    try expect((try lfu.get(2)).? == 20);
    try expect((try lfu.get(2)).? == 20);
    try expect((try lfu.get(3)).? == 30);
    try expect((try lfu.get(4)).? == 40);
    try expect((try lfu.get(4)).? == 40);
    try expect((try lfu.get(5)).? == 50);
    try expect((try lfu.get(5)).? == 50);

    try expect(lfu.getUses(1).? == 2);
    try expect(lfu.getUses(3).? == 1);

    // Putting in key '6' should overwrite '3'
    try lfu.put(6, 60);

    try expect((try lfu.get(3)) == null);
    try expect((try lfu.get(6)).? == 60);
    try expect(lfu.getUses(6).? == 1);
    try expect((try lfu.get(6)).? == 60);
    try expect(lfu.getUses(6).? == 2);
    try expect((try lfu.get(6)).? == 60);
    try expect(lfu.getUses(6).? == 3);
}

test "Manual eviction" {
    const IntLFU = AutoLFU(i32, i32);

    var lfu = IntLFU.init(std.testing.allocator, 5);
    defer lfu.deinit();

    try lfu.put(1, 10);
    _ = lfu.evict(1);
}
