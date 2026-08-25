# GAROCA
GAROCA = GasRouteCalculator

What will it do? 
- calculate your driven route (distance, visualizing on map) based on gas receipts you upload
- Upgrades: 
    - Calculate total gasoline consumption (amount, price)
    - Calculate avg. consumption (100K or manual set distance) 
    - Calculate total time spent driving

How will it do that?
1. user uploads picture of receipt (either on phone via camera or a scan -> jpg or pdf)
2. Some OCR framework (or ML model) will analyze the receipts and extract necessary information, e.g. address of gas stations, consumption, dates, amount paid
3. Extracted information are stored in a database (local or cloud-based)
4. Aggregated information are calculated, visualized and stored in database 

Technology used 
- python: for general logic and handling of information extraction, input/output handling, calculations, storing + retrieving data
- DuckDB: storing data 
- OCR framework?
- ML model? 

Questions
- Is the software a local application that needs to be installed on a desktop?
- Is it a native app / web-app? --> [Kivy](https://kivy.org) for building iOS app from Python
- If it’s supposed to be an app, how can python code be converted into app-code? 
- How reliable will information extraction from receipts be? Are receipts all equal? (Probably not)
