package vision_pkg;
    // Marker positions always remain in native 320x240 coordinates. orientation
    // rotates only glyph sampling; it cannot change the B/C coordinate contract.
    typedef struct packed {
        logic accepted, isBlue;
        logic [3:0] digit;
        logic [1:0] orientation;
        logic [7:0] quality, reason;
        logic [6:0] segments;
        logic [8:0] xMin,xMax;
        logic [7:0] yMin,yMax;
    } marker_t;
    // Sixteen completed slots are shared by both colours. isBlue carries the
    // observed colour; neither slot order nor slot address implies colour/ID.
    typedef marker_t [15:0] markerArray_t;

    // Internal, same-frame geometry. These are NOT additional B/C wire fields.
    // Corners use signed native half-pixels, in positive-area cyclic order.
    // Accepted digits use their independently observed anchor orientation;
    // an unnumbered thin colour component keeps its canonical cyclic order.
    // valid proves only a bounded convex colour component, never a digit/type.
    typedef struct packed {
        logic valid;
        logic signed [3:0][10:0] x;
        logic signed [3:0][10:0] y;
    } colourQuad_t;
    typedef colourQuad_t [15:0] colourQuadArray_t;

    // Inset sampling polygons use native Q4 coordinates (1/16 pixel). All
    // four vertices must lie inside the image before a sampler may latch them.
    typedef struct packed {
        logic valid;
        logic [3:0][12:0] x;
        logic [3:0][12:0] y;
    } samplePolygon_t;
endpackage
