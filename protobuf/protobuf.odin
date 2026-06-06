package protobuf

import "message"

// Encodes into a new byte buffer allocated with `allocator`.
encode_with_allocator :: message.encode_with_allocator

// Decodes into a newly allocated message owned by `allocator`.
decode_with_allocator :: message.decode_with_allocator

// Split ownership decoder.
// - result_allocator owns persistent data for `dest`.
// - scratch_allocator is used for temporary allocations during decode only.
// You can free the scratch_allocator after decode returns.
decode_into_with_allocators :: message.decode_into_with_allocators

encode :: message.encode
decode :: message.decode
