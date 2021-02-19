const std = @import("std");
const utils = @import("utils.zig");
const RocResult = utils.RocResult;
const mem = std.mem;
const Allocator = mem.Allocator;

const EqFn = fn (?[*]u8, ?[*]u8) callconv(.C) bool;
const Opaque = ?[*]u8;

const Inc = fn (?[*]u8) callconv(.C) void;
const Dec = fn (?[*]u8) callconv(.C) void;

pub const RocList = extern struct {
    bytes: ?[*]u8,
    length: usize,

    pub fn len(self: RocList) usize {
        return self.length;
    }

    pub fn isEmpty(self: RocList) bool {
        return self.len() == 0;
    }

    pub fn empty() RocList {
        return RocList{ .bytes = null, .length = 0 };
    }

    pub fn isUnique(self: RocList) bool {
        // the empty list is unique (in the sense that copying it will not leak memory)
        if (self.isEmpty()) {
            return true;
        }

        // otherwise, check if the refcount is one
        const ptr: [*]usize = @ptrCast([*]usize, @alignCast(8, self.bytes));
        return (ptr - 1)[0] == utils.REFCOUNT_ONE;
    }

    pub fn allocate(
        allocator: *Allocator,
        alignment: usize,
        length: usize,
        element_size: usize,
    ) RocList {
        const data_bytes = length * element_size;

        return RocList{
            .bytes = utils.allocateWithRefcount(allocator, alignment, data_bytes),
            .length = length,
        };
    }

    pub fn makeUnique(self: RocList, allocator: *Allocator, alignment: usize, element_width: usize) RocList {
        if (self.isEmpty()) {
            return self;
        }

        if (self.isUnique()) {
            return self;
        }

        // unfortunately, we have to clone
        var new_list = RocList.allocate(allocator, alignment, self.length, element_width);

        var old_bytes: [*]u8 = @ptrCast([*]u8, self.bytes);
        var new_bytes: [*]u8 = @ptrCast([*]u8, new_list.bytes);

        const number_of_bytes = self.len() * element_width;
        @memcpy(new_bytes, old_bytes, number_of_bytes);

        // NOTE we fuse an increment of all keys/values with a decrement of the input dict
        const data_bytes = self.len() * element_width;
        utils.decref(allocator, alignment, self.bytes, data_bytes);

        return new_list;
    }

    pub fn reallocate(
        self: RocList,
        allocator: *Allocator,
        alignment: usize,
        new_length: usize,
        element_width: usize,
    ) RocList {
        const old_length = self.length;
        const delta_length = new_length - old_length;

        const data_bytes = new_capacity * slot_size;
        const first_slot = allocateWithRefcount(allocator, alignment, data_bytes);

        // transfer the memory

        if (self.bytes) |source_ptr| {
            const dest_ptr = first_slot;

            @memcpy(dest_ptr, source_ptr, old_length);
        }

        // NOTE the newly added elements are left uninitialized

        const result = RocList{
            .dict_bytes = first_slot,
            .length = new_length,
        };

        // NOTE we fuse an increment of all keys/values with a decrement of the input dict
        utils.decref(allocator, alignment, self.bytes, old_length * element_width);

        return result;
    }
};

const Caller1 = fn (?[*]u8, ?[*]u8, ?[*]u8) callconv(.C) void;
const Caller2 = fn (?[*]u8, ?[*]u8, ?[*]u8, ?[*]u8) callconv(.C) void;

pub fn listMap(list: RocList, transform: Opaque, caller: Caller1, alignment: usize, old_element_width: usize, new_element_width: usize) callconv(.C) RocList {
    if (list.bytes) |source_ptr| {
        const size = list.len();
        var i: usize = 0;
        const output = RocList.allocate(std.heap.c_allocator, alignment, size, new_element_width);
        const target_ptr = output.bytes orelse unreachable;

        while (i < size) : (i += 1) {
            caller(transform, source_ptr + (i * old_element_width), target_ptr + (i * new_element_width));
        }

        utils.decref(std.heap.c_allocator, alignment, list.bytes, size * old_element_width);

        return output;
    } else {
        return RocList.empty();
    }
}

pub fn listMapWithIndex(list: RocList, transform: Opaque, caller: Caller2, alignment: usize, old_element_width: usize, new_element_width: usize) callconv(.C) RocList {
    if (list.bytes) |source_ptr| {
        const size = list.len();
        var i: usize = 0;
        const output = RocList.allocate(std.heap.c_allocator, alignment, size, new_element_width);
        const target_ptr = output.bytes orelse unreachable;

        while (i < size) : (i += 1) {
            caller(transform, @ptrCast(?[*]u8, &i), source_ptr + (i * old_element_width), target_ptr + (i * new_element_width));
        }

        utils.decref(std.heap.c_allocator, alignment, list.bytes, size * old_element_width);

        return output;
    } else {
        return RocList.empty();
    }
}

pub fn listKeepIf(list: RocList, transform: Opaque, caller: Caller1, alignment: usize, element_width: usize, inc: Inc, dec: Dec) callconv(.C) RocList {
    if (list.bytes) |source_ptr| {
        const size = list.len();
        var i: usize = 0;
        var output = RocList.allocate(std.heap.c_allocator, alignment, list.len(), list.len() * element_width);
        const target_ptr = output.bytes orelse unreachable;

        var kept: usize = 0;
        while (i < size) : (i += 1) {
            var keep = false;
            const element = source_ptr + (i * element_width);
            inc(element);
            caller(transform, element, @ptrCast(?[*]u8, &keep));

            if (keep) {
                @memcpy(target_ptr + (kept * element_width), element, element_width);

                kept += 1;
            } else {
                dec(element);
            }
        }

        // consume the input list
        utils.decref(std.heap.c_allocator, alignment, list.bytes, size * element_width);

        if (kept == 0) {
            // if the output is empty, deallocate the space we made for the result
            utils.decref(std.heap.c_allocator, alignment, output.bytes, size * element_width);
            return RocList.empty();
        } else {
            output.length = kept;

            return output;
        }
    } else {
        return RocList.empty();
    }
}

pub fn listKeepOks(list: RocList, transform: Opaque, caller: Caller1, alignment: usize, before_width: usize, result_width: usize, after_width: usize, dec_result: Dec) callconv(.C) RocList {
    return listKeepResult(list, RocResult.isOk, transform, caller, alignment, before_width, result_width, after_width, dec_result);
}

pub fn listKeepErrs(list: RocList, transform: Opaque, caller: Caller1, alignment: usize, before_width: usize, result_width: usize, after_width: usize, dec_result: Dec) callconv(.C) RocList {
    return listKeepResult(list, RocResult.isErr, transform, caller, alignment, before_width, result_width, after_width, dec_result);
}

pub fn listKeepResult(list: RocList, is_good_constructor: fn (RocResult) bool, transform: Opaque, caller: Caller1, alignment: usize, before_width: usize, result_width: usize, after_width: usize, dec_result: Dec) RocList {
    if (list.bytes) |source_ptr| {
        const size = list.len();
        var i: usize = 0;
        var output = RocList.allocate(std.heap.c_allocator, alignment, list.len(), list.len() * after_width);
        const target_ptr = output.bytes orelse unreachable;

        var temporary = @ptrCast([*]u8, std.heap.c_allocator.alloc(u8, result_width) catch unreachable);

        var kept: usize = 0;
        while (i < size) : (i += 1) {
            const before_element = source_ptr + (i * before_width);
            caller(transform, before_element, temporary);

            const result = utils.RocResult{ .bytes = temporary };

            const after_element = temporary + @sizeOf(i64);
            if (is_good_constructor(result)) {
                @memcpy(target_ptr + (kept * after_width), after_element, after_width);
                kept += 1;
            } else {
                dec_result(temporary);
            }
        }

        utils.decref(std.heap.c_allocator, alignment, list.bytes, size * before_width);
        std.heap.c_allocator.free(temporary[0..result_width]);

        if (kept == 0) {
            utils.decref(std.heap.c_allocator, alignment, output.bytes, size * after_width);
            return RocList.empty();
        } else {
            output.length = kept;
            return output;
        }
    } else {
        return RocList.empty();
    }
}

pub fn listWalk(list: RocList, stepper: Opaque, stepper_caller: Caller2, accum: Opaque, alignment: usize, element_width: usize, accum_width: usize, output: Opaque) callconv(.C) void {
    if (accum_width == 0) {
        return;
    }

    @memcpy(output orelse unreachable, accum orelse unreachable, accum_width);

    if (list.bytes) |source_ptr| {
        var i: usize = 0;
        const size = list.len();
        while (i < size) : (i += 1) {
            const element = source_ptr + i * element_width;
            stepper_caller(stepper, element, output, output);
        }

        const data_bytes = list.len() * element_width;
        utils.decref(std.heap.c_allocator, alignment, list.bytes, data_bytes);
    }
}

pub fn listWalkBackwards(list: RocList, stepper: Opaque, stepper_caller: Caller2, accum: Opaque, alignment: usize, element_width: usize, accum_width: usize, output: Opaque) callconv(.C) void {
    if (accum_width == 0) {
        return;
    }

    @memcpy(output orelse unreachable, accum orelse unreachable, accum_width);

    if (list.bytes) |source_ptr| {
        const size = list.len();
        var i: usize = size;
        while (i > 0) {
            i -= 1;
            const element = source_ptr + i * element_width;
            stepper_caller(stepper, element, output, output);
        }

        const data_bytes = list.len() * element_width;
        utils.decref(std.heap.c_allocator, alignment, list.bytes, data_bytes);
    }
}

// List.contains : List k, k -> Bool
pub fn listContains(list: RocList, key: Opaque, key_width: usize, is_eq: EqFn) callconv(.C) bool {
    if (list.bytes) |source_ptr| {
        const size = list.len();
        var i: usize = 0;
        while (i < size) : (i += 1) {
            const element = source_ptr + i * key_width;
            if (is_eq(element, key)) {
                return true;
            }
        }
    }

    return false;
}

pub fn listRepeat(count: usize, alignment: usize, element: Opaque, element_width: usize, inc_n_element: Inc) callconv(.C) RocList {
    if (count == 0) {
        return RocList.empty();
    }

    const allocator = std.heap.c_allocator;
    var output = RocList.allocate(allocator, alignment, count, element_width);

    if (output.bytes) |target_ptr| {
        var i: usize = 0;
        const source = element orelse unreachable;
        while (i < count) : (i += 1) {
            @memcpy(target_ptr + i * element_width, source, element_width);
        }

        // TODO do all increments at once!
        i = 0;
        while (i < count) : (i += 1) {
            inc_n_element(element);
        }

        return output;
    } else {
        unreachable;
    }
}
