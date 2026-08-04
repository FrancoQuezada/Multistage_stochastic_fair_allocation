include("stochastic.jl")

function main()
    Omega=[32,128,512,1024,16384]
    # ratio_pv=[0.2,0.6,0.8]
    theta=[0.2,0.6,0.8]
    # fairness=["aggregated SA", "SSA"]
    max_d=200.0
    # capacity=max_d*ratio_pv
    J=5
    T=24
    df=DataFrame()
    df[!,"Instance"]=[]
    df[!,"Scenarios"]=[]
    df[!,"theta"]=[]
    df[!,"RP"]=[]
    df[!,"EEV"]=[]
    # df[!,"RP"]=[]
    df[!,"VSS"]=[]
    for o in Omega
        # for f in fairness
            # for r in ratio_pv
                for th in theta
                    # for s_max in capacity
                        for file in readdir("../inst/inst2020")
                            inst=create2S(o,max_d, th, J, T,"../inst/inst2020/"*file)
                            solDet, barP=solve!(inst," ")
                            eev=twoS(inst,"",barP,true)
                            rp=twoS(inst,"")
                            vss=((sum(eev.costs)-sum(rp.costs))/sum(rp.costs))
                            push!(df,[file,o,th,sum(rp.costs),sum(eev.costs),vss])
                            CSV.write("../figs/excel/stoch2stageFinalVSS.csv" ,df)
                        end
                        
                    # end
                end
            # end
        # end
    end
    return true
end

main()