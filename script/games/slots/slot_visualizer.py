#!/usr/bin/env python3
"""Slot outcomes and multipliers visualizer (GUI).

Run:
  python script/games/slots/slot_visualizer.py
"""

import csv
import random
import tkinter as tk
from tkinter import ttk, filedialog, messagebox

# Data copied from DeployAllGames.s.sol (current config)
SLOTS_MULTIPLIERS_CURRENT = [
    5, 3, 3,
    3, 3, 3,
    3, 2, 2,
    2, 2, 2,
    2, 2, 2,
    2, 2, 2,
    2, 2, 2,
    2, 2, 2,
    2, 2, 2,
    2, 2, 2,
    2, 2, 2,
    2, 2, 2,
    2, 2, 2,
    2, 2, 2,
    2, 2, 2,
    2, 2, 2,
    2, 10, 10,
    12, 12, 20,
    20, 45, 100,
]

SLOTS_OUTCOMES = [
    0, 1, 2,
    3, 4, 5,
    6, 7, 8,
    9, 10, 11,
    12, 13, 14,
    15, 16, 17,
    18, 19, 20,
    21, 22, 23,
    24, 25, 26,
    27, 28, 29,
    30, 31, 32,
    33, 34, 35,
    36, 37, 38,
    39, 40, 41,
    42, 43, 44,
    45, 46, 47,
    48, 114, 117,
    171, 173, 228,
    229, 285, 342,
]

# Proposed RTP config for 3 rows (reduce top payout by 6)
SLOTS_MULTIPLIERS_RTP_96_3ROWS = [
    5, 3, 3,
    3, 3, 3,
    3, 2, 2,
    2, 2, 2,
    2, 2, 2,
    2, 2, 2,
    2, 2, 2,
    2, 2, 2,
    2, 2, 2,
    2, 2, 2,
    2, 2, 2,
    2, 2, 2,
    2, 2, 2,
    2, 2, 2,
    2, 2, 2,
    2, 2, 2,
    2, 10, 10,
    12, 12, 20,
    20, 45, 94,
]

CONFIGS = {
    "Current (RTP ~97.96%, 1 row)": {
        "multipliers": SLOTS_MULTIPLIERS_CURRENT,
        "outcomes": SLOTS_OUTCOMES,
        "rows_per_spin": 1,
    },
    "Proposed RTP ~96.27%, 3 rows": {
        "multipliers": SLOTS_MULTIPLIERS_RTP_96_3ROWS,
        "outcomes": SLOTS_OUTCOMES,
        "rows_per_spin": 3,
    },
}


def _parse_int(value, default=None):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def build_data(multipliers, outcomes):
    if len(multipliers) != len(outcomes):
        raise ValueError("Multipliers and outcomes length mismatch")

    return [
        {
            "index": idx,
            "outcome": outcomes[idx],
            "multiplier": multipliers[idx],
        }
        for idx in range(len(outcomes))
    ]


def compute_rtp(multipliers, num_outcomes=343):
    full = [0] * num_outcomes
    for outcome, multiplier in zip(SLOTS_OUTCOMES, multipliers):
        full[outcome] = multiplier
    total = sum(full)
    return total / num_outcomes, total


def filter_data(data_rows, min_outcome, max_outcome, min_multiplier, max_multiplier, search_text):
    search_text = (search_text or "").strip().lower()
    filtered = []
    for row in data_rows:
        outcome = row["outcome"]
        multiplier = row["multiplier"]

        if min_outcome is not None and outcome < min_outcome:
            continue
        if max_outcome is not None and outcome > max_outcome:
            continue
        if min_multiplier is not None and multiplier < min_multiplier:
            continue
        if max_multiplier is not None and multiplier > max_multiplier:
            continue

        if search_text:
            if search_text not in str(outcome).lower() and search_text not in str(multiplier).lower():
                continue

        filtered.append(row)
    return filtered


class SlotVisualizer(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Slots Outcome Visualizer")
        self.geometry("860x640")

        self.bonus_outcomes = {}
        self.current_config_name = list(CONFIGS.keys())[1]
        self.current_config = CONFIGS[self.current_config_name]
        self.current_data = build_data(
            self.current_config["multipliers"],
            self.current_config["outcomes"],
        )

        self._build_ui()
        self._populate_table(self.current_data)
        self._update_summary(self.current_data)

    def _build_ui(self):
        container = ttk.Frame(self, padding=12)
        container.pack(fill=tk.BOTH, expand=True)

        filter_frame = ttk.LabelFrame(container, text="Filters", padding=10)
        filter_frame.pack(fill=tk.X)

        self.min_outcome_var = tk.StringVar()
        self.max_outcome_var = tk.StringVar()
        self.min_multiplier_var = tk.StringVar()
        self.max_multiplier_var = tk.StringVar()
        self.search_var = tk.StringVar()

        ttk.Label(filter_frame, text="Outcome min:").grid(row=0, column=0, sticky=tk.W, padx=4, pady=4)
        ttk.Entry(filter_frame, textvariable=self.min_outcome_var, width=10).grid(row=0, column=1, padx=4, pady=4)

        ttk.Label(filter_frame, text="Outcome max:").grid(row=0, column=2, sticky=tk.W, padx=4, pady=4)
        ttk.Entry(filter_frame, textvariable=self.max_outcome_var, width=10).grid(row=0, column=3, padx=4, pady=4)

        ttk.Label(filter_frame, text="Multiplier min:").grid(row=0, column=4, sticky=tk.W, padx=4, pady=4)
        ttk.Entry(filter_frame, textvariable=self.min_multiplier_var, width=10).grid(row=0, column=5, padx=4, pady=4)

        ttk.Label(filter_frame, text="Multiplier max:").grid(row=0, column=6, sticky=tk.W, padx=4, pady=4)
        ttk.Entry(filter_frame, textvariable=self.max_multiplier_var, width=10).grid(row=0, column=7, padx=4, pady=4)

        ttk.Label(filter_frame, text="Search:").grid(row=1, column=0, sticky=tk.W, padx=4, pady=4)
        ttk.Entry(filter_frame, textvariable=self.search_var, width=20).grid(row=1, column=1, padx=4, pady=4)

        ttk.Label(filter_frame, text="Config:").grid(row=2, column=0, sticky=tk.W, padx=4, pady=4)
        self.config_var = tk.StringVar(value=self.current_config_name)
        config_menu = ttk.OptionMenu(
            filter_frame,
            self.config_var,
            self.current_config_name,
            *CONFIGS.keys(),
            command=self.apply_config,
        )
        config_menu.grid(row=2, column=1, sticky=tk.W, padx=4, pady=4)

        self.rows_var = tk.StringVar(value=f"Rows per spin: {self.current_config['rows_per_spin']}")
        ttk.Label(filter_frame, textvariable=self.rows_var).grid(
            row=2, column=2, columnspan=2, sticky=tk.W, padx=4, pady=4
        )

        ttk.Button(filter_frame, text="Apply", command=self.apply_filters).grid(row=1, column=2, padx=4, pady=4)
        ttk.Button(filter_frame, text="Reset", command=self.reset_filters).grid(row=1, column=3, padx=4, pady=4)
        ttk.Button(filter_frame, text="Export CSV", command=self.export_csv).grid(row=1, column=4, padx=4, pady=4)

        slot_frame = ttk.LabelFrame(container, text="Slot Machine", padding=10)
        slot_frame.pack(fill=tk.X, pady=(10, 0))

        reels_frame = ttk.Frame(slot_frame)
        reels_frame.pack(side=tk.LEFT)

        self.reel_vars = [tk.StringVar(value="—") for _ in range(3)]
        for idx, reel_var in enumerate(self.reel_vars):
            label = ttk.Label(
                reels_frame,
                textvariable=reel_var,
                font=("Helvetica", 24, "bold"),
                relief=tk.RIDGE,
                padding=(16, 8),
                width=4,
                anchor=tk.CENTER,
            )
            label.grid(row=0, column=idx, padx=6)

        controls_frame = ttk.Frame(slot_frame)
        controls_frame.pack(side=tk.LEFT, padx=16)

        self.spin_result_var = tk.StringVar(value="Spin to see outcome")
        ttk.Button(controls_frame, text="Spin", command=self.spin).pack(anchor=tk.W)
        ttk.Label(controls_frame, textvariable=self.spin_result_var, wraplength=360).pack(anchor=tk.W, pady=(6, 0))

        bonus_frame = ttk.LabelFrame(container, text="Bonus Outcomes", padding=10)
        bonus_frame.pack(fill=tk.X, pady=(10, 0))

        self.bonus_outcome_var = tk.StringVar()
        self.bonus_rounds_var = tk.StringVar()
        self.bonus_profit_var = tk.StringVar()
        self.bonus_label_var = tk.StringVar()

        ttk.Label(bonus_frame, text="Outcome:").grid(row=0, column=0, sticky=tk.W, padx=4, pady=4)
        ttk.Entry(bonus_frame, textvariable=self.bonus_outcome_var, width=10).grid(row=0, column=1, padx=4, pady=4)

        ttk.Label(bonus_frame, text="Extra rounds:").grid(row=0, column=2, sticky=tk.W, padx=4, pady=4)
        ttk.Entry(bonus_frame, textvariable=self.bonus_rounds_var, width=10).grid(row=0, column=3, padx=4, pady=4)

        ttk.Label(bonus_frame, text="Extra profit:").grid(row=0, column=4, sticky=tk.W, padx=4, pady=4)
        ttk.Entry(bonus_frame, textvariable=self.bonus_profit_var, width=10).grid(row=0, column=5, padx=4, pady=4)

        ttk.Label(bonus_frame, text="Label:").grid(row=0, column=6, sticky=tk.W, padx=4, pady=4)
        ttk.Entry(bonus_frame, textvariable=self.bonus_label_var, width=16).grid(row=0, column=7, padx=4, pady=4)

        ttk.Button(bonus_frame, text="Add/Update", command=self.add_bonus).grid(row=0, column=8, padx=4, pady=4)
        ttk.Button(bonus_frame, text="Remove", command=self.remove_bonus).grid(row=0, column=9, padx=4, pady=4)

        self.bonus_tree = ttk.Treeview(
            bonus_frame,
            columns=("outcome", "rounds", "profit", "label"),
            show="headings",
            height=4,
        )
        self.bonus_tree.heading("outcome", text="Outcome")
        self.bonus_tree.heading("rounds", text="Extra rounds")
        self.bonus_tree.heading("profit", text="Extra profit")
        self.bonus_tree.heading("label", text="Label")
        self.bonus_tree.column("outcome", width=100, anchor=tk.CENTER)
        self.bonus_tree.column("rounds", width=120, anchor=tk.CENTER)
        self.bonus_tree.column("profit", width=120, anchor=tk.CENTER)
        self.bonus_tree.column("label", width=200, anchor=tk.W)
        self.bonus_tree.grid(row=1, column=0, columnspan=10, sticky=tk.W + tk.E, padx=4, pady=4)

        self.summary_var = tk.StringVar(value="")
        ttk.Label(container, textvariable=self.summary_var).pack(anchor=tk.W, pady=(8, 4))

        table_frame = ttk.Frame(container)
        table_frame.pack(fill=tk.BOTH, expand=True)

        self.tree = ttk.Treeview(
            table_frame,
            columns=("index", "outcome", "multiplier"),
            show="headings",
            selectmode="browse",
        )
        self.tree.heading("index", text="#")
        self.tree.heading("outcome", text="Outcome")
        self.tree.heading("multiplier", text="Multiplier")
        self.tree.column("index", width=60, anchor=tk.CENTER)
        self.tree.column("outcome", width=120, anchor=tk.CENTER)
        self.tree.column("multiplier", width=120, anchor=tk.CENTER)

        vsb = ttk.Scrollbar(table_frame, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=vsb.set)

        self.tree.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        vsb.pack(side=tk.RIGHT, fill=tk.Y)

    def _populate_table(self, rows):
        for item in self.tree.get_children():
            self.tree.delete(item)

        for row in rows:
            self.tree.insert("", tk.END, values=(row["index"], row["outcome"], row["multiplier"]))

    def _update_summary(self, rows):
        if not rows:
            self.summary_var.set("No results")
            return

        multipliers = [r["multiplier"] for r in rows]
        outcomes = [r["outcome"] for r in rows]
        rtp, total = compute_rtp(self.current_config["multipliers"])
        rows_per_spin = self.current_config["rows_per_spin"]
        summary = (
            f"Rows: {len(rows)} | "
            f"Outcome range: {min(outcomes)}–{max(outcomes)} | "
            f"Multiplier range: {min(multipliers)}–{max(multipliers)} | "
            f"Bonus outcomes: {len(self.bonus_outcomes)} | "
            f"RTP: {rtp:.2%} (sum {total}) | "
            f"Rows/spin: {rows_per_spin}"
        )
        self.summary_var.set(summary)

    def apply_filters(self):
        min_outcome = _parse_int(self.min_outcome_var.get())
        max_outcome = _parse_int(self.max_outcome_var.get())
        min_multiplier = _parse_int(self.min_multiplier_var.get())
        max_multiplier = _parse_int(self.max_multiplier_var.get())
        search_text = self.search_var.get()

        rows = filter_data(self.current_data, min_outcome, max_outcome, min_multiplier, max_multiplier, search_text)
        self._populate_table(rows)
        self._update_summary(rows)

    def reset_filters(self):
        self.min_outcome_var.set("")
        self.max_outcome_var.set("")
        self.min_multiplier_var.set("")
        self.max_multiplier_var.set("")
        self.search_var.set("")
        self._populate_table(self.current_data)
        self._update_summary(self.current_data)

    def export_csv(self):
        file_path = filedialog.asksaveasfilename(
            defaultextension=".csv",
            filetypes=[("CSV Files", "*.csv")],
        )
        if not file_path:
            return

        rows = []
        for item in self.tree.get_children():
            values = self.tree.item(item, "values")
            rows.append(values)

        try:
            with open(file_path, "w", newline="") as csvfile:
                writer = csv.writer(csvfile)
                writer.writerow(["index", "outcome", "multiplier"])
                writer.writerows(rows)
        except OSError as exc:
            messagebox.showerror("Export failed", str(exc))
            return

        messagebox.showinfo("Export complete", f"Saved to {file_path}")

    def spin(self):
        row = random.choice(self.current_data)
        outcome = row["outcome"]
        multiplier = row["multiplier"]

        digits = list(str(outcome).rjust(3, "0"))
        for idx, digit in enumerate(digits[-3:]):
            self.reel_vars[idx].set(digit)

        bonus = self.bonus_outcomes.get(outcome)
        if bonus:
            bonus_text = (
                f"Bonus! Outcome {outcome} → x{multiplier} | "
                f"+{bonus['rounds']} rounds | +{bonus['profit']} profit "
                f"({bonus['label']})"
            )
        else:
            bonus_text = f"Outcome {outcome} → x{multiplier}"

        self.spin_result_var.set(bonus_text)
        self._highlight_row(row["index"])

    def _highlight_row(self, index):
        for item in self.tree.get_children():
            values = self.tree.item(item, "values")
            if values and int(values[0]) == index:
                self.tree.selection_set(item)
                self.tree.see(item)
                break

    def add_bonus(self):
        outcome = _parse_int(self.bonus_outcome_var.get())
        rounds = _parse_int(self.bonus_rounds_var.get(), 0)
        profit = _parse_int(self.bonus_profit_var.get(), 0)
        label = (self.bonus_label_var.get() or "").strip()

        if outcome is None:
            messagebox.showerror("Invalid input", "Outcome must be an integer")
            return

        if outcome not in SLOTS_OUTCOMES:
            messagebox.showerror("Invalid outcome", "Outcome is not in the slots outcome list")
            return

        self.bonus_outcomes[outcome] = {
            "rounds": rounds,
            "profit": profit,
            "label": label or "Bonus",
        }
        self._refresh_bonus_table()
        self._update_summary(self.current_data)

    def remove_bonus(self):
        outcome = _parse_int(self.bonus_outcome_var.get())
        if outcome is None:
            messagebox.showerror("Invalid input", "Outcome must be an integer")
            return

        if outcome in self.bonus_outcomes:
            del self.bonus_outcomes[outcome]
            self._refresh_bonus_table()
            self._update_summary(self.current_data)
        else:
            messagebox.showinfo("Not found", "No bonus configured for that outcome")

    def _refresh_bonus_table(self):
        for item in self.bonus_tree.get_children():
            self.bonus_tree.delete(item)

        for outcome in sorted(self.bonus_outcomes.keys()):
            bonus = self.bonus_outcomes[outcome]
            self.bonus_tree.insert(
                "",
                tk.END,
                values=(outcome, bonus["rounds"], bonus["profit"], bonus["label"]),
            )

    def apply_config(self, *_):
        self.current_config_name = self.config_var.get()
        self.current_config = CONFIGS[self.current_config_name]
        self.current_data = build_data(
            self.current_config["multipliers"],
            self.current_config["outcomes"],
        )
        self.rows_var.set(f"Rows per spin: {self.current_config['rows_per_spin']}")
        self._populate_table(self.current_data)
        self._update_summary(self.current_data)


if __name__ == "__main__":
    app = SlotVisualizer()
    app.mainloop()
