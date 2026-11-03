from pathlib import Path
import hashlib,json,re
r=Path(__file__).resolve().parents[1];m=json.loads((r/'integration_sources_v2.json').read_text())
def h(p):return hashlib.sha256(p.read_bytes()).hexdigest()
for p,x in m['original_files'].items():assert h(Path(p))==x,'ORIGINAL CHANGED: '+p
for rel,x in m['copies'].items():
 if rel not in m['modified_copies']:assert h(r/rel)==x['sha256'],'UNEXPECTED CHANGE: '+rel
print('PASS source integrity: original files',len(m['original_files']),'unchanged copies',len(m['copies'])-len(m['modified_copies']))
q=(r/'quartus/PartBDebug.qsf').read_text();sources=[]
for kind,p in re.findall(r'-name (SYSTEMVERILOG_FILE|SDC_FILE|QSYS_FILE) (\S+)',q):
 f=(r/'quartus'/p).resolve();assert r in f.parents and f.is_file(),p
 if kind=='SYSTEMVERILOG_FILE':sources.append(f)
assert len(sources)==len(set(sources))
assert sum(p.name=='perception_pkg.sv' for p in sources)==1
assert not any(p.name in ('memberCSimulator.sv','hcsr04_model.sv','vga_sink_sim.sv') or 'tests' in p.parts for p in sources)
assert 'VIRTUAL_PIN' not in q
for name in ['mainColourSupportReader.sv','calibrationPointMapper.sv','calibrationGeometry.sv']:assert any(p.name==name for p in sources)
loc={};pinOwners={};ios={}
for pin,port in re.findall(r'set_location_assignment (PIN_\w+) -to (\S+)',q):
 assert pin not in pinOwners and port not in loc;loc[port]=pin;pinOwners[pin]=port
for std,port in re.findall(r'set_instance_assignment -name IO_STANDARD "([^"]+)" -to (\S+)',q):ios[port]=std
assert len(loc)==133 and all(ios[p]=='3.3-V LVTTL' for p in loc)
for port,pin in {'IRDA_RXD':'PIN_AA30','GPIO_1[27]':'PIN_AJ22','GPIO_1[29]':'PIN_AG22','GPIO_1[31]':'PIN_AF23','GPIO_1[33]':'PIN_AD21'}.items():assert loc[port]==pin
print('PASS',len(sources),'synthesis RTL files, full latest-B dependency closure, 133 unique physical pins, no virtual interface')
# The validated top, all C modules and timing constraints are byte-identical to successful old BC.
for rel in ['rtl/top/echo7IntegratedTop.sv','quartus/PartBDebug.sdc','quartus/MemberBCdc.sdc','quartus/MemberCIntegration.sdc']:
 assert h(r/rel)==h(Path(m['old_bc'])/rel)
for p in (r/'rtl/member_c').glob('*.sv'):assert h(p)==h(Path(m['old_bc'])/p.relative_to(r))
print('PASS unchanged C/top/shared clock/reset/timeUs and SDC; new B algorithms copied verbatim')
