from bisect import bisect_right
import re
class VCD:
    def __init__(self,path):
        self.path=path
        raw=path.read_text()
        ts=re.search(r'\$timescale\s+(\d+)\s*(s|ms|us|ns|ps|fs)\s+\$end',raw)
        scale=int(ts[1])*{'s':1e9,'ms':1e6,'us':1e3,'ns':1,'ps':.001,'fs':.000001}[ts[2]]
        self.names={};self.width={};self.events={};scope=[];t=0
        for line in raw.splitlines():
            a=line.split()
            if not a:continue
            if a[0]=='$scope':scope.append(a[2])
            elif a[0]=='$upscope':scope.pop()
            elif a[0]=='$var':
                n='.'.join(scope+[a[4]]);self.names[n]=a[3];self.width[n]=int(a[2]);self.events.setdefault(a[3],[])
            elif line.startswith('#'):t=int(line[1:])*scale
            elif line[0] in '01xXzZbB':
                value,code=(a[0][1:],a[1]) if line[0] in 'bB' else (line[0],line[1:])
                if code not in self.events:continue
                value=value.lower();value=value if 'x' in value or 'z' in value else int(value,2)
                ev=self.events[code]
                if ev and ev[-1][0]==t:ev[-1]=(t,value)
                elif not ev or ev[-1][1]!=value:ev.append((t,value))
    def trace(self,n):return self.events[self.names['tb_instruction.'+n]]
    def value(self,n,t):
        ev=self.trace(n);i=bisect_right([x[0] for x in ev],t)-1
        return ev[i][1] if i>=0 else 'x'
    def points(self,n,a,b):return [(a,self.value(n,a))]+[(t,v) for t,v in self.trace(n) if a<t<b]+[(b,self.value(n,b))]
    def first(self,n,value):return next(t for t,v in self.trace(n) if v==value)

