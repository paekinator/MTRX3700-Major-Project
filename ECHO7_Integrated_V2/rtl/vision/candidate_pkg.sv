// ECHO-7 Part A | Human owner: Member A (name/SID pending).
// New project code, AI-assisted by OpenAI Codex; human review required.
package candidate_pkg;
    // One completed pool is shared by red/blue, independent of temporary CCL
    // handles. A parallel bitmap identifies colour for each occupied slot.
    // Sixteen outputs need a five-bit count (the value16 is not a label).
    localparam int MAX_CANDIDATES = 16;
    typedef struct packed {
        logic       valid;
        logic [8:0] xmin, xmax;
        logic [7:0] ymin, ymax;
        logic [16:0] area;
        logic [8:0] cx;
        logic [7:0] cy;
    } candidate_t;
    typedef candidate_t [MAX_CANDIDATES-1:0] candidate_array_t;
endpackage
