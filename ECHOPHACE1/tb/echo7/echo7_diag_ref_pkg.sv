// ECHO-7 Phase 1.5 | Team-owned, AI-assisted self-checking references; human review pending.
package echo7_diag_ref_pkg;
    import echo7_diag_pkg::*;
    function automatic region_acc_t collect(input region_acc_t old,
        input int x,y,input logic [29:0] pixel);
        region_acc_t r;
        r=old;
        if(old.area==0 || x<int'(old.xmin)) r.xmin=10'(x);
        if(old.area==0 || x>int'(old.xmax)) r.xmax=10'(x);
        if(old.area==0 || y<int'(old.ymin)) r.ymin=9'(y);
        if(old.area==0 || y>int'(old.ymax)) r.ymax=9'(y);
        r.area=old.area+1;
        r.sum_r=old.sum_r+int'(pixel[29:22]);
        r.sum_g=old.sum_g+int'(pixel[19:12]);
        r.sum_b=old.sum_b+int'(pixel[9:2]);
        return r;
    endfunction
    function automatic logic [11:0] ref_decimal(input int n);
        return {4'(n/100),4'((n/10)%10),4'(n%10)};
    endfunction
    function automatic string decimal_text(input int n);
        // SystemVerilog %03d is space-padded in ModelSim 10.5b. Specify zeros explicitly.
        return {byte'(48+n/100),byte'(48+(n/10)%10),byte'(48+n%10)};
    endfunction
    function automatic region_result_t finish_region(input region_acc_t a);
        region_result_t r;
        int rr,gg,bb,mn,mx,d,h,s,rc,gc,bc,sector;
        r='0;
        if(!a.valid || a.area==0 || a.overflow) return r;
        rr=(int'(a.sum_r)+int'(a.area)/2)/int'(a.area);
        gg=(int'(a.sum_g)+int'(a.area)/2)/int'(a.area);
        bb=(int'(a.sum_b)+int'(a.area)/2)/int'(a.area);
        if(rr>255) rr=255; if(gg>255) gg=255; if(bb>255) bb=255;
        mx=rr>gg ? rr:gg; if(bb>mx) mx=bb;
        mn=rr<gg ? rr:gg; if(bb<mn) mn=bb;
        d=mx-mn; h=0; s=0;
        if(mx!=0) s=(255*d+mx/2)/mx;
        // Textbook max-channel distances, rather than the RTL's signed RGB differences.
        if(d!=0) begin
            rc=mx-rr; gc=mx-gg; bc=mx-bb;
            if(mx==rr) sector=bc-gc;
            else if(mx==gg) sector=2*d+rc-bc;
            else sector=4*d+gc-rc;
            if(sector<0) sector+=6*d;
            h=((60*sector+d/2)/d)%360;
        end
        r.valid=1; r.xmin=a.xmin; r.xmax=a.xmax; r.ymin=a.ymin; r.ymax=a.ymax; r.area=a.area;
        r.r=8'(rr); r.g=8'(gg); r.b=8'(bb); r.h=9'(h); r.s=8'(s); r.v=8'(mx);
        r.rgb_digits={ref_decimal(rr),ref_decimal(gg),ref_decimal(bb)};
        r.hsv_digits={ref_decimal(h),ref_decimal(s),ref_decimal(mx)};
        return r;
    endfunction
    // Golden glyph artwork, independent of the DUT's dynamic bit addressing.
    function automatic logic [34:0] reference_font(input byte c);
        case(c)
            "0": return 35'b01110_10001_10011_10101_11001_10001_01110;
            "1": return 35'b00100_01100_00100_00100_00100_00100_01110;
            "2": return 35'b01110_10001_00001_00010_00100_01000_11111;
            "3": return 35'b11110_00001_00001_01110_00001_00001_11110;
            "4": return 35'b00010_00110_01010_10010_11111_00010_00010;
            "5": return 35'b11111_10000_10000_11110_00001_00001_11110;
            "6": return 35'b01110_10000_10000_11110_10001_10001_01110;
            "7": return 35'b11111_00001_00010_00100_01000_01000_01000;
            "8": return 35'b01110_10001_10001_01110_10001_10001_01110;
            "9": return 35'b01110_10001_10001_01111_00001_00001_01110;
            "R": return 35'b11110_10001_10001_11110_10100_10010_10001;
            "E": return 35'b11111_10000_10000_11110_10000_10000_11111;
            "D": return 35'b11110_10001_10001_10001_10001_10001_11110;
            "B": return 35'b11110_10001_10001_11110_10001_10001_11110;
            "L": return 35'b10000_10000_10000_10000_10000_10000_11111;
            "U": return 35'b10001_10001_10001_10001_10001_10001_01110;
            "G": return 35'b01110_10001_10000_10111_10001_10001_01110;
            "H": return 35'b10001_10001_10001_11111_10001_10001_10001;
            "S": return 35'b01111_10000_10000_01110_00001_00001_11110;
            "V": return 35'b10001_10001_10001_10001_10001_01010_00100;
            ":": return 35'b00000_00100_00100_00000_00100_00100_00000;
            "M": return 35'b10001_11011_10101_10101_10001_10001_10001;
            "O": return 35'b01110_10001_10001_10001_10001_10001_01110;
            "F": return 35'b11111_10000_10000_11110_10000_10000_10000;
            "I": return 35'b11111_00100_00100_00100_00100_00100_11111;
            "X": return 35'b10001_10001_01010_00100_01010_10001_10001;
            "A": return 35'b01110_10001_10001_11111_10001_10001_10001;
            "T": return 35'b11111_00100_00100_00100_00100_00100_00100;
            "C": return 35'b01111_10000_10000_10000_10000_10000_01111;
            "Y": return 35'b10001_10001_01010_00100_00100_00100_00100;
            "N": return 35'b10001_11001_11001_10101_10011_10011_10001;
            ",": return 35'b00000_00000_00000_00000_00100_00100_01000;
            "-": return 35'b00000_00000_00000_11111_00000_00000_00000;
            default: return 0;
        endcase
    endfunction
    function automatic logic [30:0] reference_graphics(input int x,y,
        input region_result_t red,blue,input bit hsv);
        region_result_t regions[2];
        int lx[2],ly[2];
        int local_x,local_y,column,row;
        bit hit;
        logic [29:0] pixel;
        logic [34:0] bitmap;
        string label_text;
        regions[0]=red; regions[1]=blue; hit=0; pixel=0;
        for(int k=0;k<2;k++) begin
            lx[k]=int'(regions[k].xmin); if(lx[k]>376) lx[k]=376;
            ly[k]=int'(regions[k].ymax)+2;
            if(ly[k]>464) begin
                ly[k]=int'(regions[k].ymin)-18;
                if(ly[k]<0) ly[k]=464;
            end
            if(regions[k].valid && x>=int'(regions[k].xmin) && x<=int'(regions[k].xmax) &&
                y>=int'(regions[k].ymin) && y<=int'(regions[k].ymax) &&
                (x==int'(regions[k].xmin) || x==int'(regions[k].xmax) ||
                 y==int'(regions[k].ymin) || y==int'(regions[k].ymax))) begin
                hit=1; pixel={8'd0,2'b0,8'd255,2'b0,8'd0,2'b0};
            end
        end
        if(red.valid && blue.valid && lx[0]+264>lx[1] && lx[1]+264>lx[0] &&
           ly[0]+16>ly[1] && ly[1]+16>ly[0]) begin
            ly[1]=ly[0]+18; if(ly[1]>464) ly[1]=ly[0]-18;
        end
        for(int k=1;k>=0;k--) begin
            if(regions[k].valid && x>=lx[k] && x<lx[k]+264 && y>=ly[k] && y<ly[k]+16) begin
                if(hsv) label_text={k==0 ? "RED " : "BLUE"," H:",decimal_text(int'(regions[k].h))," S:",decimal_text(int'(regions[k].s))," V:",decimal_text(int'(regions[k].v))};
                else label_text={k==0 ? "RED " : "BLUE"," R:",decimal_text(int'(regions[k].r))," G:",decimal_text(int'(regions[k].g))," B:",decimal_text(int'(regions[k].b))};
                local_x=x-lx[k]; local_y=y-ly[k];
                column=(local_x%12)/2; row=local_y/2;
                bitmap=reference_font(label_text[local_x/12]);
                hit=1; pixel=0;
                if(column<5 && row<7 && ((bitmap>>(5*(6-row))) & (5'b10000>>column)))
                    pixel={8'd255,2'b0,8'd255,2'b0,8'd255,2'b0};
            end
        end
        if(x<0 || x>=640 || y<0 || y>=480) hit=0;
        return {hit,pixel};
    endfunction
endpackage
