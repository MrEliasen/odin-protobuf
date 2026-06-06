package validation

// Ownership proof for the split-allocator decoder. Decodes into a result arena
// using a SEPARATE scratch arena, then frees and scribbles (0xAA) both the
// scratch arena and the input buffer. Anything the decoded message still points
// at must live in the result arena; any pointer left aliasing scratch or input
// is now corrupted, so every assertion below would fail loudly.
//
// Run with:  odin test odin_ownership_test.odin -file

import "../protobuf"
import "out/odin"

import "core:mem"
import "core:slice"
import "core:testing"

@(test)
test_decode_into_survives_scratch_destruction :: proc(t: ^testing.T) {
	// --- encode a fully populated message into its own arena ---
	encode_arena: mem.Arena
	encode_backing := make([]u8, 1 * mem.Megabyte)
	defer delete(encode_backing)
	mem.arena_init(&encode_arena, encode_backing)
	encode_alloc := mem.arena_allocator(&encode_arena)

	msg: odin.TestAllTypes
	msg.scalars.v_int32 = -123
	msg.scalars.v_bool = true
	msg.scalars.v_string = "hello world"
	msg.scalars.v_bytes = []u8{1, 2, 3, 4}

	msg.repeateds.r_int32 = []i32{0, 1, 2} // leading zero
	msg.repeateds.r_string = []string{"alpha", "beta", "gamma"}
	msg.repeateds.r_bytes = [][]u8{{9}, {8, 7}}
	msg.repeateds.r_nested = []odin.NestedMessage {
		{id = 1, name = "one", flag = true},
		{id = 2, name = "two", flag = false},
	}
	msg.repeateds.r_enum = []odin.Status{.ACTIVE, .INACTIVE}

	m_ss := make(map[string]string, encode_alloc)
	m_ss["key1"] = "value1"
	m_ss["key2"] = "value2"
	msg.maps.m_string_string = m_ss

	m_sn := make(map[string]odin.NestedMessage, encode_alloc)
	m_sn["n1"] = {
		id   = 10,
		name = "ten",
		flag = true,
	}
	msg.maps.m_string_nested = m_sn

	m_ue := make(map[u32]odin.Status, encode_alloc)
	m_ue[1] = .DELETED
	msg.maps.m_uint32_enum = m_ue

	msg.nested = {
		id   = 99,
		name = "top nested",
		flag = true,
	}
	msg.status = .ACTIVE

	bytes, enc_ok := protobuf.encode_with_allocator(msg, encode_alloc)
	testing.expect(t, enc_ok, "encode failed")

	// --- decode into a result arena using a separate scratch arena ---
	result_arena: mem.Arena
	result_backing := make([]u8, 1 * mem.Megabyte)
	defer delete(result_backing)
	mem.arena_init(&result_arena, result_backing)
	result_alloc := mem.arena_allocator(&result_arena)

	scratch_arena: mem.Arena
	scratch_backing := make([]u8, 1 * mem.Megabyte)
	defer delete(scratch_backing)
	mem.arena_init(&scratch_arena, scratch_backing)
	scratch_alloc := mem.arena_allocator(&scratch_arena)

	dest := new(odin.TestAllTypes, result_alloc)
	dec_ok := protobuf.decode_into_with_allocators(
		odin.TestAllTypes,
		bytes,
		cast([^]u8)dest,
		result_alloc,
		scratch_alloc,
	)
	testing.expect(t, dec_ok, "decode_into failed")

	// --- POISON: nothing the message points at may live in scratch or input ---
	free_all(scratch_alloc)
	slice.fill(scratch_backing, 0xAA)
	free_all(encode_alloc)
	slice.fill(encode_backing, 0xAA)

	// --- everything below must read clean data out of the result arena ---
	testing.expect_value(t, dest.scalars.v_int32, -123)
	testing.expect_value(t, dest.scalars.v_bool, true)
	testing.expect_value(t, dest.scalars.v_string, "hello world")
	testing.expect(t, slice.equal(dest.scalars.v_bytes, []u8{1, 2, 3, 4}), "v_bytes")

	testing.expect(t, slice.equal(dest.repeateds.r_int32, []i32{0, 1, 2}), "r_int32")

	testing.expect(t, len(dest.repeateds.r_string) == 3, "r_string len")
	testing.expect_value(t, dest.repeateds.r_string[0], "alpha")
	testing.expect_value(t, dest.repeateds.r_string[2], "gamma")

	testing.expect(t, len(dest.repeateds.r_bytes) == 2, "r_bytes len")
	testing.expect(t, slice.equal(dest.repeateds.r_bytes[0], []u8{9}), "r_bytes[0]")
	testing.expect(t, slice.equal(dest.repeateds.r_bytes[1], []u8{8, 7}), "r_bytes[1]")

	testing.expect(t, len(dest.repeateds.r_nested) == 2, "r_nested len")
	testing.expect_value(t, dest.repeateds.r_nested[0].name, "one")
	testing.expect_value(t, dest.repeateds.r_nested[0].id, 1)
	testing.expect_value(t, dest.repeateds.r_nested[1].name, "two")
	testing.expect_value(t, dest.repeateds.r_nested[1].flag, false)

	testing.expect(t, len(dest.repeateds.r_enum) == 2, "r_enum len")
	testing.expect_value(t, dest.repeateds.r_enum[1], odin.Status.INACTIVE)

	testing.expect_value(t, dest.maps.m_string_string["key1"], "value1")
	testing.expect_value(t, dest.maps.m_string_string["key2"], "value2")

	n1 := dest.maps.m_string_nested["n1"]
	testing.expect_value(t, n1.id, 10)
	testing.expect_value(t, n1.name, "ten")
	testing.expect_value(t, n1.flag, true)

	testing.expect_value(t, dest.maps.m_uint32_enum[1], odin.Status.DELETED)

	testing.expect_value(t, dest.nested.id, 99)
	testing.expect_value(t, dest.nested.name, "top nested")
	testing.expect_value(t, dest.status, odin.Status.ACTIVE)

	free_all(result_alloc)
}

// decode_into must reject a nil destination.
@(test)
test_decode_into_nil_dest :: proc(t: ^testing.T) {
	ok := protobuf.decode_into_with_allocators(
		odin.TestAllTypes,
		[]u8{0x28, 0x01}, // status = 1
		nil,
		context.temp_allocator,
		context.temp_allocator,
	)
	testing.expect(t, !ok, "nil dest must fail")
}

// decode_with_allocator must not leave transient decode scratch in the result
// allocator: decoding into a private-scratch path (B) must use strictly less of
// the result arena than decoding with scratch == result (A).
@(test)
test_decode_with_allocator_excludes_scratch :: proc(t: ^testing.T) {
	enc_arena: mem.Arena
	enc_backing := make([]u8, 256 * mem.Kilobyte)
	defer delete(enc_backing)
	mem.arena_init(&enc_arena, enc_backing)
	enc := mem.arena_allocator(&enc_arena)

	msg: odin.TestAllTypes
	msg.scalars.v_string = "the quick brown fox jumps over the lazy dog"
	msg.repeateds.r_string = []string{"alpha", "beta", "gamma", "delta"}
	m := make(map[string]string, enc)
	m["k1"] = "v1"
	m["k2"] = "v2"
	m["k3"] = "v3"
	msg.maps.m_string_string = m
	msg.nested = {
		id   = 7,
		name = "nested name",
		flag = true,
	}

	bytes, enc_ok := protobuf.encode_with_allocator(msg, enc)
	testing.expect(t, enc_ok, "encode failed")

	// A) no split: scratch == result.
	a_arena: mem.Arena
	a_backing := make([]u8, 1 * mem.Megabyte)
	defer delete(a_backing)
	mem.arena_init(&a_arena, a_backing)
	a := mem.arena_allocator(&a_arena)
	dest_a := new(odin.TestAllTypes, a)
	ok_a := protobuf.decode_into_with_allocators(
		odin.TestAllTypes,
		bytes,
		cast([^]u8)dest_a,
		a,
		a,
	)
	testing.expect(t, ok_a, "decode A failed")

	// B) decode_with_allocator: private scratch arena, freed on return.
	b_arena: mem.Arena
	b_backing := make([]u8, 1 * mem.Megabyte)
	defer delete(b_backing)
	mem.arena_init(&b_arena, b_backing)
	b := mem.arena_allocator(&b_arena)
	_, ok_b := protobuf.decode_with_allocator(odin.TestAllTypes, bytes, b)
	testing.expect(t, ok_b, "decode B failed")

	testing.expect(
		t,
		b_arena.offset < a_arena.offset,
		"decode_with_allocator must keep scratch out of the result allocator",
	)
}
