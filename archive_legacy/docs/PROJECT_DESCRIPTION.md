# Project Description

This project studies fair electricity allocation in a residential energy community under uncertainty. It implements a multistage stochastic optimization model in Julia where photovoltaic energy, household demand, and energy prices evolve along a scenario tree. The goal is to allocate local photovoltaic production and battery usage over time while minimizing expected operating cost and enforcing fairness across households.

The repository supports several fairness notions. Two proportional criteria are modeled directly in the multistage optimization problem: proportional photovoltaic energy allocation and proportional savings allocation. Two additional criteria are handled with lexicographic max-min procedures: lexicographic max-min fairness for photovoltaic energy allocation and lexicographic max-min fairness for savings allocation. These lexicographic criteria are solved through sequential linear programs that progressively refine fairness targets.

The codebase also includes tools to generate stochastic instances from photovoltaic data files, run single experiments or large batches, and export detailed CSV reports with system-level and house-level metrics. This makes the project suitable for computational experiments comparing the cost and fairness implications of different allocation rules under uncertainty.
