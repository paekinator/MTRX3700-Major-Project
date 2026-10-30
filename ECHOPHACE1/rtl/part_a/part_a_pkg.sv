// ECHO-7 Part A | Human owner: Member A (name/SID pending).
// New project code, AI-assisted by OpenAI Codex; human review required.
package part_a_pkg;
    localparam int MAX_CANDIDATES = 8;
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
