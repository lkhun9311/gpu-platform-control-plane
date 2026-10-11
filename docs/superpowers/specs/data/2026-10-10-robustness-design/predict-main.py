import sys, math, json
sys.path.insert(0,"hack/prospective-pilot")
import simulate as sim, pilot_report as pr
S=sys.argv[1]; scale=float(sys.argv[2])
dirs=["hack/m5c-20261008-235046-pilotA/m5c-run","hack/m5c-20261009-013656-pilotB/m5c-run"]
cells=[sim.load_cell(d,a,r) for d in dirs for a,r in pr.cells(d)]
coef,_=sim.fit_step_model(cells); fwd=sim.offsets(cells); lag=sim.dispatch_lag(cells)
SIZE={"short":1256.9e6,"ref":1740e6,"long":1867e6}
arms={"off":(sim.RULES["off"],0),"caponly":(sim.RULES["off"],384),"hold-cap":(sim.RULES["hold-one-prefill"],384),
      "fixed1740":(None,384),"sizeaware":(None,384)}
out={}
for L in ("short","ref","long"):
    pooled={a:[] for a in arms}; adm={a:True for a in arms if a!="off"}; why={}
    pre=[]
    for seed in (881,882,883):
        reqs=sim.load_trace(f"{S}/lr/t{seed}-off-{L}.jsonl",lag)
        res={}
        for a,(rule,cap) in arms.items():
            if a=="fixed1740": rule=sim.hold_spacing(1740e6)
            if a=="sizeaware": rule=sim.hold_spacing(SIZE[L])
            o=sim.simulate(reqs,coef,rule,fwd,8_000_000,long_prefill=cap,step_scale=scale)
            pooled[a].extend(o); res[a]=sim.summarize(o)
            if a=="hold-cap":
                pre+=[(r["first_token"]-r["engaged"])/1e6 for r in o if r["tenant"]==pr.CONTENDER and "first_token" in r and "engaged" in r]
        for a in adm:
            f=sim.owner_limits(res[a],res["off"])
            if f and adm[a]: adm[a]=False; why[a]=f"{f} seed {seed}"
    p99={a:sim.summarize(pooled[a])["premium_p99_ms"] for a in arms}
    out[L]={"p99":{a:round(v) for a,v in p99.items()},"inadmissible":why,"hc_prefill_p50":round(pr.nearest_rank(sorted(pre),0.5))}
print(json.dumps({"scale":scale,**out}))
