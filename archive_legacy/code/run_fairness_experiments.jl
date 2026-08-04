include("multi.jl")

# =======================
# Configuracion del experimento
# =======================

inst_folder = "inst/inst2020"
instance_from = 1
instance_to = 10

# Puedes usar "NONE", "PEA", "SA", "LEXMMFPEA", "LEXMMFSA"
fairness_set = ["NONE", "PEA", "SA", "LEXMMFPEA", "LEXMMFSA"]

# Cada tupla define una configuracion del scenario tree
tree_set = [
    (NBstage=2, childs=2, periods=12),
    (NBstage=3, childs=2, periods=8)
]

# Parametros del problema
J_set = [5]
theta_set = [0.2, 0.6]
avg_d_set = [100.0]
dev_d_set = [10.0]

out_csv = "fairness_config_set_report.csv"
out_csv_house = "fairness_config_set_report_by_house.csv"


function build_configs()
    if !isdir(inst_folder)
        error("No existe carpeta de instancias: $inst_folder")
    end
    files = sort(readdir(inst_folder))
    if isempty(files)
        error("No hay archivos en $inst_folder")
    end
    from = max(1, instance_from)
    to = min(length(files), instance_to)
    if from > to
        error("Rango de instancias invalido: [$instance_from,$instance_to]")
    end

    configs = NamedTuple[]
    for file in files[from:to]
        inFile = joinpath(inst_folder, file)
        for fair in fairness_set
            for tree in tree_set
                for J in J_set
                    for theta in theta_set
                        for avg_d in avg_d_set
                            for dev_d in dev_d_set
                                push!(configs, (
                                    fairness=fair,
                                    inFile=inFile,
                                    NBstage=tree.NBstage,
                                    childs=tree.childs,
                                    periods=tree.periods,
                                    J=J,
                                    theta=theta,
                                    avg_d=avg_d,
                                    dev_d=dev_d
                                ))
                            end
                        end
                    end
                end
            end
        end
    end
    return configs
end

function main()
    configs = build_configs()
    println("Total configuraciones a ejecutar: ", length(configs))
    run_fairness_config_set(configs; out_csv=out_csv, out_csv_house=out_csv_house)
    println("Reporte resumen: ", out_csv)
    println("Reporte por casa: ", out_csv_house)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
