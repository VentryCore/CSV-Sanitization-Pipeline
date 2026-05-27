from datetime import datetime
import random
import numpy as np
import pandas as pd
import os

print("     -------- CSV Fault Injector ---------")

# -----------------------------------------------------------------------
# CONFIGURATION
# Centralizing these values makes it easy to scale the dataset size,
# date range, or product catalog without touching injection logic.
# -----------------------------------------------------------------------
MONTH = datetime.now().month
YEAR  = datetime.now().year
NUM_ROWS = 20
PRODUCTS = ["gadget", "tool", "service", "subscription", "widget"]
FILE_COUNT = 50
file_number = 0

# Output directory for all generated (dirty) CSV files
os.makedirs("Chaotic Data", exist_ok=True)

for i in range(FILE_COUNT):

    file_number += 1

    # ------------------------------------------------------------------
    # BASE DATA GENERATION
    # np.random.uniform generates NUM_ROWS floats between 10.0 and 200.0.
    # np.random.randint generates NUM_ROWS integers between 1 and 28
    # (capped at 28 to avoid invalid dates like Feb 30).
    # ------------------------------------------------------------------
    prices = np.round(np.random.uniform(10.0, 200.0, NUM_ROWS), 2)
    days   = np.random.randint(1, 29, NUM_ROWS)

    data_map = {
        "Transaction ID": range(1, NUM_ROWS + 1),
        "Product":        [random.choice(PRODUCTS) for _ in range(NUM_ROWS)],
        "Price":          prices,
        "Date":           [f"{YEAR}-{MONTH}-{d}" for d in days]
    }

    df = pd.DataFrame(data_map)

    # set_index promotes "Transaction ID" to the DataFrame index,
    # replacing the default 0-based integer counter on export.
    df.set_index("Transaction ID", inplace=True)

    # Track the current price column name — it may be renamed by FAULT 4
    current_price_name = "Price"

    # ==================================================================
    # FAULT INJECTION
    # Each fault is independent and probabilistic. Together they simulate
    # the class of schema and data-quality errors common in real ETL pipelines.
    # ==================================================================

    # --- FAULT 1: Date Format Inconsistency ---
    # Replaces 5 randomly selected date values with DD/MM/YYYY format,
    # conflicting with the baseline YYYY-MM-DD format.

    poisoned_indices = random.sample(range(NUM_ROWS), 5)
    for indx in poisoned_indices:
        df.iloc[indx, df.columns.get_loc("Date")] = f"{days[indx]}/{MONTH}/{YEAR}"


    # --- FAULT 2: Row Duplication ---
    # Appends the first 2 rows to the end of the DataFrame.
    # ignore_index=False preserves the original Transaction IDs (1 & 2)
    # on the duplicated rows, making them non-trivially detectable
    # (same ID, same data — a realistic ETL double-insert scenario).

    df = pd.concat([df, df.iloc[:2]], ignore_index=False)


    # --- FAULT 3: Trailing Whitespace in Product Column ---
    # 40% probability. Appends a trailing space to every product value.
    # Whitespace-padded strings are logically identical to humans
    # but treated as distinct values by parsers and databases.

    if random.random() > 0.6:
        df['Product'] = df['Product'].apply(lambda x: x + " ")


    # --- FAULT 4: Header Name Mutation ---
    # 50% probability. Renames "Price" and "Product" to alternate aliases
    # drawn from a small vocabulary. Simulates schema drift across
    # reporting periods or source systems.

    new_price_name   = random.choice(["Cost", "Amount"])
    new_product_name = random.choice(["Item", "Gizmo"])

    if random.random() > 0.5:
        df.rename(columns={"Price": new_price_name, "Product": new_product_name}, inplace=True)
        current_price_name = new_price_name  # Keep the price column reference current
        

    # --- FAULT 5: Corrupted / Null Price Values ---
    # 40% probability. Injects a single garbage string into the Price column.
    # current_price_name and price_header_position are used to dynamically
    # locate the column even after a FAULT 4 rename.
    
    if random.random() > 0.6:
        corrupt_row          = random.randint(1, NUM_ROWS - 1)
        garbage              = random.choice(["NULL", "  ", "N/A", "NaN"])
        price_header_position = df.columns.get_loc(current_price_name)

        # Column must be cast to object dtype before inserting a string
        # into what is otherwise a float64 column.
        df[current_price_name] = df[current_price_name].astype(object)
        df.iloc[corrupt_row, price_header_position] = garbage

    # ------------------------------------------------------------------
    # EXPORT
    # Files are indexed from 1 (not 0) for human-readable referencing.
    # ------------------------------------------------------------------
    file_name = os.path.join("Chaotic Data", f"Sales_Report.{i + 1}.csv")
    df.to_csv(file_name)

print(f"\n✅ Successfully generated {file_number} fault-injected CSV files in .\\Chaotic Data")
