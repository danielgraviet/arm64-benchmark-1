# Which guest-physical pages of a clone are private (CoW-dirtied) vs shared with the template mem file?
import sys,os,struct,collections
pid=int(sys.argv[1]); PS=os.sysconf("SC_PAGE_SIZE")
start=end=None; memfile=None
for l in open(f"/proc/{pid}/maps"):
    f=l.split()
    if len(f)>=6 and f[5].endswith("/mem"):
        a,b=[int(x,16) for x in f[0].split("-")]
        if b-a>=1<<30: start,end,memfile=a,b,f[5]; break
n=(end-start)//PS
fd=os.open(f"/proc/{pid}/pagemap",os.O_RDONLY); os.lseek(fd,(start//PS)*8,0)
buf=b""
while len(buf)<n*8: buf+=os.read(fd,min(1<<24,n*8-len(buf)))
ents=struct.unpack(f"<{n}Q",buf)
# template file sparseness: data extents via SEEK_DATA/SEEK_HOLE
mf=os.open(memfile,os.O_RDONLY); size=os.fstat(mf).st_size; data=set(); off=0
SEEK_DATA,SEEK_HOLE=3,4
while off<size:
    try: d=os.lseek(mf,off,SEEK_DATA)
    except OSError: break
    h=os.lseek(mf,d,SEEK_HOLE)
    for p in range(d//PS,(h+PS-1)//PS): data.add(p)
    off=h
priv=[i for i,e in enumerate(ents) if (e>>63)&1 and not (e>>61)&1]
shared=[i for i,e in enumerate(ents) if (e>>63)&1 and (e>>61)&1]
print(f"page={PS} guest={n*PS>>20}MiB template_data_pages={len(data)} ({len(data)*PS>>20}MiB)")
print(f"private(dirtied)={len(priv)} ({len(priv)*PS>>20}MiB)  shared_from_template={len(shared)} ({len(shared)*PS>>20}MiB)")
print(f"  private over template data: {sum(1 for i in priv if i in data)}  over template holes(zero): {sum(1 for i in priv if i not in data)}")
reg=collections.Counter((i*PS)>>26 for i in priv)   # 64 MiB regions
print("  private by GPA 64MiB region (MiB):", ", ".join(f"{r*64}M:{c*PS>>20}" for r,c in sorted(reg.items()) if c*PS>>20))
runs=[];cur=None
for i in priv:
    if cur and i==cur[1]+1: cur[1]=i
    else:
        if cur: runs.append(cur[1]-cur[0]+1)
        cur=[i,i]
if cur: runs.append(cur[1]-cur[0]+1)
runs.sort()
print(f"  runs={len(runs)} median_run={runs[len(runs)//2]} pages, single-page runs={sum(1 for r in runs if r==1)}")
