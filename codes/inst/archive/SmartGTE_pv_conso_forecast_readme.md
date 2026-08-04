# Readme of file SmartGTE_pv_conso_forecast_*.csv

# Creation date: 28/06/2025
# Contact : Jordi Badosa (jordi.badosa@lmd.polytechnique.fr)

# This file combines electric consumption measuerements from 4 buildings of Ecole polytechnique with photovoltaic (PV) production estimation using SIRTA's radiative, temperature and wind speed measurements and PV forecast from ARPEGE MeteoFrance Numerical Weather Predictions (of solar irradiance, air temperature and wind speed) 

# PV is computed (whether from SIRTA measurements or ARPEGE forecasts) from solar irradiance, wind speed and air temperature, using python pvlib v0.13 functions, considering a PV installed capacity of 62 kWp with PV modules tilted 10º towards South. 
In particular, the methods used are : 
- plane of array irradiance :  pvlib.pvsystem.sapm_effective_irradiance
- PV cell temperature : pvlib.temperature.sapm_cell
- PV DC power : pvlib.pvsystem.pvwatts_dc
- PV AC power : pvlib.inverter.pvwatts

# Time step : 5 minutes 
- For Consumption : native resolution is 5 minutes (instantaneaus power samples)
- For ARPEGE : 5-minute interpolation computed from the 1-hour native time step
- For SIRTA measurements : 5-minute averages computed from the 1-min native time step  

# Missing Data :
The file has two main periods of missing data:
- For consumption: Approximately between January 6 and 18, 2025
- For the AROME-PEARP forecast: Approximately from November 20, 2024, to January 9, 2025

# Columns information : 
- Date and time (UTC), Universal time 
- power_conso_bat_a, power_conso_bat_b, power_conso_bat_c, power_conso_bat_d : electric consumption from buildings A, B, C and D, respectively (in kW) 
- pv_real : PV estimations from solar irradiance, air temperature and wind speed measured at SIRTA observatory (in kW)
- pv_arpege : PV forecast estimation from ARPEGE solar irradiance, air temperature and wind speed forecasts (in kW)
- airtemp_arpege : Air temperature forecast from ARPEGE (in ºC) 

# DOI : 
- https://doi.org/10.14768/094a7485-b312-482c-8cb6-59d1f5a72acf

# Licence : 
- Data : under license CC BY-NC 4.0 (https://creativecommons.org/licenses/by-nc/4.0/)
- The use of data and code for AI training is forbidden without explicit authorization.

# Contact : 
- For any questions or further information, please contact e4c_datahub@ip-paris.fr.
