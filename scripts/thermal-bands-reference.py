"""Python reference for map step 3. No production weather or fitted cut table."""
import math
import statistics


def neighbours(points):
    def distance(a,b):
        return math.hypot((a['longitude']-b['longitude'])*math.cos(math.radians((a['latitude']+b['latitude'])/2)),a['latitude']-b['latitude'])
    near=[sorted([j for j in range(len(points)) if i!=j],key=lambda j:distance(points[i],points[j])) for i in range(len(points))]
    if any(distance(points[i],points[row[0]])==0 for i,row in enumerate(near)):raise ValueError('Duplicate grid')
    return near,distance


def resolution(points,history,near,distance):
    best=None
    for k in sorted({min(k,len(points)-1) for k in [3,4,6,8]}):
        year_errors=[];year_medians=[]
        for year in history:
            residuals=[]
            for p in range(len(points)):
                nn=near[p][:k]
                weights=[1/distance(points[p],points[j])**2 for j in nn]
                for i,value in enumerate(year[p]):
                    predicted=sum(year[j][i]*w for j,w in zip(nn,weights))/sum(weights)
                    residuals.append(abs(value-predicted))
            year_errors.append(statistics.mean(residuals));year_medians.append(statistics.median(residuals))
        error=statistics.mean(year_errors)
        if best is None or error<best[0]:best=(error,max(1e-6,statistics.median(year_medians)*1.4826),k)
    return best[1:]


def partitions(values):
    a=sorted(values);n=len(a);origin=min(a);s=[0.];ss=[0.]
    for v in a:s.append(s[-1]+v-origin);ss.append(ss[-1]+(v-origin)**2)
    def cost(i,j):return max(0,ss[j]-ss[i]-(s[j]-s[i])**2/(j-i))
    K=min(5,n);dp=[[math.inf]*(n+1) for _ in range(K+1)];back=[[0]*(n+1) for _ in range(K+1)];dp[0][0]=0
    for k in range(1,K+1):
        for end in range(k,n+1):
            for start in range(k-1,end):
                if start and a[start-1]==a[start]:continue
                v=dp[k-1][start]+cost(start,end)
                if v<dp[k][end]:dp[k][end]=v;back[k][end]=start
    result=[]
    for k in range(1,K+1):
        if not math.isfinite(dp[k][n]):continue
        end=n;cuts=[]
        for level in range(k,1,-1):
            start=back[level][end];cuts.append((a[start-1]+a[start])/2);end=start
        result.append(sorted(cuts))
    return result


def evaluate(cuts,values,near,k,sigma):
    labels=[sum(v>=cut for cut in cuts) for v in values]
    groups=[[v for v,label in zip(values,labels) if label==i] for i in range(len(cuts)+1)]
    if any(not g for g in groups):return dict(cuts=cuts,score=math.inf,labels=labels)
    means=[statistics.mean(g) for g in groups]
    sse=sum((v-means[label])**2 for v,label in zip(values,labels))
    islands=sum(all(labels[j]!=label for j in near[i][:k]) for i,label in enumerate(labels))
    score=len(values)*math.log(max(sse/len(values),sigma*sigma))+(2*len(groups)-1+islands)*math.log(len(values))
    return dict(cuts=cuts,labels=labels,score=score,means=means,pointCounts=[len(g) for g in groups],isolatedSamples=islands)


def build(points,values,history,previous=None):
    if len(points)<2 or len(values)!=len(points) or not all(math.isfinite(v) for v in values):raise ValueError('Bad points/current data')
    if len(history)<3:raise ValueError('Insufficient historical years')
    if any(len(y)!=len(points) or not y[0] or any(len(p)!=len(y[0]) or not all(math.isfinite(v) for v in p) for p in y) for y in history):raise ValueError('Bad history')
    near,distance=neighbours(points);sigma,k=resolution(points,history,near,distance)
    best=min([evaluate(c,values,near,k,sigma) for c in partitions(values)],key=lambda c:c['score'])
    retained=False
    if previous is not None:
        old=evaluate(previous.get('baseCuts',previous['cuts']),values,near,k,sigma)
        if old['score']<=best['score']+math.log(len(values)):best=old;retained=True
    base_cuts=best['cuts'][:]
    edges=[min(values)]+base_cuts+[max(values)];cuts=[]
    for i,(lower,upper) in enumerate(zip(edges,edges[1:])):
        pieces=max(1,math.ceil((upper-lower)/3))
        cuts.extend(lower+(upper-lower)*j/pieces for j in range(1,pieces))
        if i<len(edges)-2:cuts.append(upper)
    labels=[sum(v>=cut for cut in cuts) for v in values]
    final_edges=[min(values)]+cuts+[max(values)]
    groups=[[v for v,label in zip(values,labels) if label==i] for i in range(len(cuts)+1)]
    result=dict(best,cuts=cuts,baseCuts=base_cuts,labels=labels,
        means=[statistics.mean(g) if g else (final_edges[i]+final_edges[i+1])/2 for i,g in enumerate(groups)],
        pointCounts=[len(g) for g in groups],widths=[b-a for a,b in zip(final_edges,final_edges[1:])],
        historicalSpatialError=sigma,selectedNeighbourCount=k,retainedPreviousCuts=retained)
    return result
