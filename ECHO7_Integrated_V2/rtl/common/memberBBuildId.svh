// An unqualified manual GUI build has no verified source identity. The CLI
// replaces this header only in its isolated source copy with the real hash.
// Never leave a previous build's identity attached to changed working sources.
`define MEMBER_B_BUILD_ID 32'h00000000
