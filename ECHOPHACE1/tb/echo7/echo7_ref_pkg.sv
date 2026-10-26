// ECHO-7 Phase 1 | Owner: MTRX3700 ECHO-7 team; human review required.
// AI-assisted test code: OpenAI Codex. See OWNERS.md and AI_STATEMENT.md.
package echo7_ref_pkg;
    // Independent integer reference: do not call camera_pkg or DUT helper logic.
    function automatic int channel(input logic [15:0] p, input int c);
        int q;
        case(c)
            0: begin q=(int'(p)>>11)&31; return q*8+q/4; end
            1: begin q=(int'(p)>>5)&63; return q*4+q/16; end
            default: begin q=int'(p)&31; return q*8+q/4; end
        endcase
    endfunction
    function automatic logic [29:0] video(input logic [15:0] p);
        return {8'(channel(p,0)),2'b00,8'(channel(p,1)),2'b00,8'(channel(p,2)),2'b00};
    endfunction
    function automatic logic [1:0] classify(input logic [15:0] p, input int algorithm);
        int r,g,b,v,mn,d,n,s,hfloor,hceil;
        bit red,blue;
        r=channel(p,0); g=channel(p,1); b=channel(p,2);
        red=0; blue=0;
        case(algorithm)
            1: begin
                red=(r>=80 && 2*r>=3*g && 2*r>=3*b);
                blue=(b>=80 && 2*b>=3*r && 2*b>=3*g);
            end
            2: begin
                v=r; if(g>v) v=g; if(b>v) v=b;
                mn=r; if(g<mn) mn=g; if(b<mn) mn=b;
                d=v-mn;
                if(d>0 && v>=80) begin
                    s=255*d/v;
                    if(v==r) n=256*(g-b);
                    else if(v==g) n=256*(b-r)+512*d;
                    else n=256*(r-g)+1024*d;
                    if(n<0) n+=1536*d;
                    // Floor for inclusive lower bound, ceil for inclusive upper bound.
                    hfloor=n/d; hceil=(n+d-1)/d;
                    red=(s>=96 && (hceil<=85 || hfloor>=1451));
                    blue=(s>=96 && hfloor>=853 && hceil<=1109);
                end
            end
            default: begin
                red=(r>=160 && g<=100 && b<=100);
                blue=(b>=160 && r<=100 && g<=100);
            end
        endcase
        return (red==blue) ? 2'b00 : red ? 2'b01 : 2'b10;
    endfunction
    function automatic logic [29:0] overlay(input logic [29:0] p,input logic [1:0] mask,input bit enable);
        if(enable && mask==1) return {8'hff,2'b00,8'h00,2'b00,8'h00,2'b00};
        if(enable && mask==2) return {8'h00,2'b00,8'h00,2'b00,8'hff,2'b00};
        return p;
    endfunction
    typedef struct packed {
        logic [29:0] data;
        logic [1:0] mask;
        logic sop,eop,enable;
    } transaction;
endpackage
