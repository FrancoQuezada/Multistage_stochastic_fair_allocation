include("vss.jl")

inst_folder = "inst/inst2020"
instance_from = 1
instance_to = 10

fairness_set = ["NONE", "PEA", "SA", "LEXMMFPEA", "LEXMMFSA"]

tree = (NBstage=6, childs=2, periods=4)
J = 5
theta = 0.2
avg_d = 100.0
dev_d = 10.0

out_csv = "vss_report.csv"

function main()
    df = run_vss_report(
        inst_folder=inst_folder,
        instance_from=instance_from,
        instance_to=instance_to,
        NBstage=tree.NBstage,
        childs=tree.childs,
        periods=tree.periods,
        J=J,
        theta=theta,
        avg_d=avg_d,
        dev_d=dev_d,
        fairness_list=fairness_set,
        out_csv=out_csv
    )
    println("Filas generadas: ", nrow(df))
    println("Reporte VSS: ", out_csv)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
