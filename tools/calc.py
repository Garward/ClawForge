#!/home/garward/Scripts/Tools/.venv/bin/python3
"""
Safe math evaluation tool for ClawForge.

Evaluates math expressions without arbitrary code execution.
Supports arithmetic, math functions, unit conversions, and batch operations.

Usage:
    python3 calc.py '2 + 2'
    python3 calc.py '{"expressions": ["22.86 / 150", "7.19 / 18", "round(0.1524, 2)"]}'
    python3 calc.py '{"expression": "22.86 / (12.5 * 12)", "label": "price_per_oz"}'
    python3 calc.py '{"convert": 2.5, "from": "lb", "to": "oz"}'
    python3 calc.py '{"sort": [{"name": "A", "value": 3.2}, {"name": "B", "value": 1.1}], "by": "value", "order": "asc"}'
"""

import ast
import json
import math
import operator
import sys

# Whitelisted operations for safe evaluation
SAFE_OPS = {
    ast.Add: operator.add,
    ast.Sub: operator.sub,
    ast.Mult: operator.mul,
    ast.Div: operator.truediv,
    ast.FloorDiv: operator.floordiv,
    ast.Mod: operator.mod,
    ast.Pow: operator.pow,
    ast.USub: operator.neg,
    ast.UAdd: operator.pos,
}

SAFE_FUNCTIONS = {
    "round": round,
    "abs": abs,
    "min": min,
    "max": max,
    "sum": sum,
    "len": len,
    "sqrt": math.sqrt,
    "ceil": math.ceil,
    "floor": math.floor,
    "log": math.log,
    "log10": math.log10,
    "log2": math.log2,
    "pow": pow,
    "pi": math.pi,
    "e": math.e,
}

SAFE_COMPARISONS = {
    ast.Gt: operator.gt,
    ast.GtE: operator.ge,
    ast.Lt: operator.lt,
    ast.LtE: operator.le,
    ast.Eq: operator.eq,
    ast.NotEq: operator.ne,
}

# Unit conversion factors (all relative to a base unit per category)
UNIT_CONVERSIONS = {
    # Weight: base = grams
    "g": ("weight", 1.0),
    "gram": ("weight", 1.0),
    "grams": ("weight", 1.0),
    "kg": ("weight", 1000.0),
    "kilogram": ("weight", 1000.0),
    "oz": ("weight", 28.3495),
    "ounce": ("weight", 28.3495),
    "ounces": ("weight", 28.3495),
    "lb": ("weight", 453.592),
    "lbs": ("weight", 453.592),
    "pound": ("weight", 453.592),
    "pounds": ("weight", 453.592),
    "mg": ("weight", 0.001),
    "milligram": ("weight", 0.001),
    # Volume: base = ml
    "ml": ("volume", 1.0),
    "milliliter": ("volume", 1.0),
    "l": ("volume", 1000.0),
    "liter": ("volume", 1000.0),
    "liters": ("volume", 1000.0),
    "fl_oz": ("volume", 29.5735),
    "floz": ("volume", 29.5735),
    "cup": ("volume", 236.588),
    "cups": ("volume", 236.588),
    "tbsp": ("volume", 14.787),
    "tablespoon": ("volume", 14.787),
    "tsp": ("volume", 4.929),
    "teaspoon": ("volume", 4.929),
    "gal": ("volume", 3785.41),
    "gallon": ("volume", 3785.41),
    "pint": ("volume", 473.176),
    "quart": ("volume", 946.353),
    # Length: base = meters
    "m": ("length", 1.0),
    "meter": ("length", 1.0),
    "meters": ("length", 1.0),
    "cm": ("length", 0.01),
    "mm": ("length", 0.001),
    "km": ("length", 1000.0),
    "in": ("length", 0.0254),
    "inch": ("length", 0.0254),
    "inches": ("length", 0.0254),
    "ft": ("length", 0.3048),
    "foot": ("length", 0.3048),
    "feet": ("length", 0.3048),
    "yd": ("length", 0.9144),
    "yard": ("length", 0.9144),
    "mi": ("length", 1609.34),
    "mile": ("length", 1609.34),
    "miles": ("length", 1609.34),
    # Temperature handled separately
    "c": ("temperature", None),
    "celsius": ("temperature", None),
    "f": ("temperature", None),
    "fahrenheit": ("temperature", None),
    "k": ("temperature", None),
    "kelvin": ("temperature", None),
    # Energy: base = calories
    "cal": ("energy", 1.0),
    "calorie": ("energy", 1.0),
    "calories": ("energy", 1.0),
    "kcal": ("energy", 1000.0),
    "kilocalorie": ("energy", 1000.0),
    "kj": ("energy", 239.006),  # 1 kJ = 239.006 cal
    "kilojoule": ("energy", 239.006),
}


def safe_eval(expr: str) -> float | int | bool | list:
    """Safely evaluate a math expression using AST parsing.

    Only allows numbers, arithmetic ops, whitelisted functions, and comparisons.
    No attribute access, imports, or arbitrary code execution.
    """
    try:
        tree = ast.parse(expr, mode="eval")
    except SyntaxError as e:
        raise ValueError(f"Invalid expression: {e}")

    return _eval_node(tree.body)


def _eval_node(node):
    # Numbers
    if isinstance(node, ast.Constant):
        if isinstance(node.value, (int, float)):
            return node.value
        if isinstance(node.value, bool):
            return node.value
        raise ValueError(f"Unsupported constant type: {type(node.value).__name__}")

    # Unary ops: -x, +x
    if isinstance(node, ast.UnaryOp):
        op = SAFE_OPS.get(type(node.op))
        if op is None:
            raise ValueError(f"Unsupported unary operator: {type(node.op).__name__}")
        return op(_eval_node(node.operand))

    # Binary ops: x + y, x * y, etc.
    if isinstance(node, ast.BinOp):
        op = SAFE_OPS.get(type(node.op))
        if op is None:
            raise ValueError(f"Unsupported operator: {type(node.op).__name__}")
        left = _eval_node(node.left)
        right = _eval_node(node.right)
        if isinstance(node.op, ast.Div) and right == 0:
            raise ValueError("Division by zero")
        if isinstance(node.op, ast.Pow) and abs(right) > 1000:
            raise ValueError("Exponent too large (max 1000)")
        return op(left, right)

    # Comparisons: x > y, x == y, etc.
    if isinstance(node, ast.Compare):
        left = _eval_node(node.left)
        for op_node, comparator in zip(node.ops, node.comparators):
            op = SAFE_COMPARISONS.get(type(op_node))
            if op is None:
                raise ValueError(f"Unsupported comparison: {type(op_node).__name__}")
            right = _eval_node(comparator)
            if not op(left, right):
                return False
            left = right
        return True

    # Function calls: round(x, 2), sqrt(x), min(a, b, c)
    if isinstance(node, ast.Call):
        if not isinstance(node.func, ast.Name):
            raise ValueError("Only named function calls are supported")
        func_name = node.func.id
        if func_name not in SAFE_FUNCTIONS:
            raise ValueError(f"Unknown function: {func_name}")
        func = SAFE_FUNCTIONS[func_name]
        args = [_eval_node(a) for a in node.args]
        return func(*args)

    # Name references (pi, e)
    if isinstance(node, ast.Name):
        if node.id in SAFE_FUNCTIONS:
            val = SAFE_FUNCTIONS[node.id]
            if isinstance(val, (int, float)):
                return val
        raise ValueError(f"Unknown variable: {node.id}")

    # List literals: [1, 2, 3] for min/max/sum
    if isinstance(node, ast.List):
        return [_eval_node(el) for el in node.elts]

    # Tuple literals for function args
    if isinstance(node, ast.Tuple):
        return tuple(_eval_node(el) for el in node.elts)

    raise ValueError(f"Unsupported expression type: {type(node).__name__}")


def convert_temperature(value: float, from_unit: str, to_unit: str) -> float:
    """Convert between C, F, K."""
    f = from_unit.lower()
    t = to_unit.lower()
    if f in ("c", "celsius"):
        celsius = value
    elif f in ("f", "fahrenheit"):
        celsius = (value - 32) * 5 / 9
    elif f in ("k", "kelvin"):
        celsius = value - 273.15
    else:
        raise ValueError(f"Unknown temperature unit: {from_unit}")

    if t in ("c", "celsius"):
        return round(celsius, 4)
    elif t in ("f", "fahrenheit"):
        return round(celsius * 9 / 5 + 32, 4)
    elif t in ("k", "kelvin"):
        return round(celsius + 273.15, 4)
    else:
        raise ValueError(f"Unknown temperature unit: {to_unit}")


def convert_units(value: float, from_unit: str, to_unit: str) -> dict:
    """Convert between units. Returns result with full context."""
    fu = from_unit.lower().strip()
    tu = to_unit.lower().strip()

    if fu not in UNIT_CONVERSIONS:
        return {"error": f"Unknown unit: {from_unit}", "supported": list(UNIT_CONVERSIONS.keys())}
    if tu not in UNIT_CONVERSIONS:
        return {"error": f"Unknown unit: {to_unit}", "supported": list(UNIT_CONVERSIONS.keys())}

    from_cat, from_factor = UNIT_CONVERSIONS[fu]
    to_cat, to_factor = UNIT_CONVERSIONS[tu]

    if from_cat != to_cat:
        return {"error": f"Cannot convert between {from_cat} and {to_cat}"}

    if from_cat == "temperature":
        result = convert_temperature(value, fu, tu)
    else:
        # Convert to base unit, then to target
        base_value = value * from_factor
        result = round(base_value / to_factor, 6)

    return {
        "input": value,
        "from": from_unit,
        "to": to_unit,
        "result": result,
        "expression": f"{value} {from_unit} = {result} {to_unit}",
    }


def sort_items(items: list[dict], by: str, order: str = "asc") -> list[dict]:
    """Sort a list of dicts by a given key."""
    reverse = order.lower() in ("desc", "descending")

    def sort_key(item):
        val = item.get(by)
        if val is None:
            return float("inf") if not reverse else float("-inf")
        return val

    sorted_list = sorted(items, key=sort_key, reverse=reverse)
    for i, item in enumerate(sorted_list):
        item["rank"] = i + 1
    return sorted_list


def process_request(raw_input: str) -> dict:
    """Process a calc request. Accepts expression string or JSON object."""
    raw = raw_input.strip()

    # Try JSON first
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        # Plain expression string
        data = {"expression": raw}

    # If it's a plain string after JSON parse, treat as expression
    if isinstance(data, str):
        data = {"expression": data}

    if not isinstance(data, dict):
        return {"error": "Input must be a JSON object or a math expression string"}

    # --- Unit conversion ---
    if "convert" in data:
        return convert_units(
            float(data["convert"]),
            data.get("from", ""),
            data.get("to", ""),
        )

    # --- Sort ---
    if "sort" in data:
        return {
            "sorted": sort_items(
                data["sort"],
                data.get("by", "value"),
                data.get("order", "asc"),
            )
        }

    # --- Batch expressions ---
    if "expressions" in data:
        results = []
        for expr_item in data["expressions"]:
            if isinstance(expr_item, str):
                expr = expr_item
                label = expr_item
            elif isinstance(expr_item, dict):
                expr = expr_item.get("expression", "")
                label = expr_item.get("label", expr)
            else:
                results.append({"expression": str(expr_item), "error": "Invalid expression format"})
                continue

            try:
                val = safe_eval(expr)
                results.append({"label": label, "expression": expr, "result": val})
            except (ValueError, TypeError, ZeroDivisionError, OverflowError) as e:
                results.append({"label": label, "expression": expr, "error": str(e)})
        return {"results": results}

    # --- Single expression ---
    if "expression" in data:
        expr = data["expression"]
        label = data.get("label", expr)
        try:
            val = safe_eval(expr)
            return {"label": label, "expression": expr, "result": val}
        except (ValueError, TypeError, ZeroDivisionError, OverflowError) as e:
            return {"expression": expr, "error": str(e)}

    return {"error": "Provide 'expression', 'expressions', 'convert', or 'sort'"}


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "No input provided. Pass a math expression or JSON object."}))
        sys.exit(1)

    raw_input = " ".join(sys.argv[1:])
    result = process_request(raw_input)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
