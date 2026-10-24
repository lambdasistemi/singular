# Tool, not a guarantee: replay the frozen investigation; no hosted job runs it.
"""Compile money and accepted-economic substitutions in an isolated namespace."""

import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
BASE = ROOT / "lean/NoPin/ApplicationRequests"


def check():
    sources = {
        name: (BASE / (name + ".lean")).read_text()
        for name in ["Money", "MoneyClaims", "MoneyStatements", "MoneyUpdate"]
    }
    sources["MoneyStatements"] = re.sub(
        r":= by.*?(?=\n/--|\nend NoPin.ApplicationRequests.Money.Statements)",
        ":= by sorry\n",
        sources["MoneyStatements"],
        flags=re.S,
    )
    sources["MoneyUpdate"] = (
        sources["MoneyUpdate"].split("end Statements", 1)[0]
        + "end Statements\nend NoPin.ApplicationRequests.Money\n"
    )
    sources["MoneyUpdate"] = re.sub(
        r"(?<=:= by).*?(?=\nend Statements)",
        " sorry\n",
        sources["MoneyUpdate"],
        flags=re.S,
    )
    accepted = (
        ROOT.parent.parent / "lean/Singular/Economics/FoldProjection.lean"
    ).read_text()
    accepted = accepted[accepted.index("def foldObligations") :].split(
        "end Singular", 1
    )[0]
    results = {}
    with tempfile.TemporaryDirectory(
        prefix="money-proof-control-", dir=ROOT / ".lake"
    ) as directory:
        for label in [
            "positive",
            "changed-money-allocation",
            "changed-accepted-economic-definition",
        ]:
            current = dict(sources)
            producer = accepted
            if label == "changed-money-allocation":
                needle = "amountAt m .oldRegistrationCarrier obligations.carriers"
                if current["Money"].count(needle) != 1:
                    raise ValueError("money mutation is not unique")
                current["Money"] = current["Money"].replace(
                    needle, "amountAt m .oldRegistrationCarrier obligations.donation"
                )
                if needle in current["Money"]:
                    raise ValueError("money mutation did not apply")
            if label == "changed-accepted-economic-definition":
                needle = "(members.map FoldMember.tip).sum"
                if producer.count(needle) != 1:
                    raise ValueError("accepted economic mutation is not unique")
                producer = producer.replace(
                    needle, "(members.map FoldMember.carrier).sum"
                )
                if needle in producer:
                    raise ValueError("accepted mutation did not apply")
            current["Money"] = current["Money"].replace(
                "let obligations := foldObligations",
                "let obligations := NoPin.AcceptedMoneyControl.foldObligations",
            )
            text = "import NoPin.ApplicationRequests.MoneyProofAudit\nopen NoPin.ApplicationRequests\n"
            text += (
                "namespace NoPin.AcceptedMoneyControl\nopen Singular\n"
                + producer
                + "\nend NoPin.AcceptedMoneyControl\n"
            )
            for source in current.values():
                text += (
                    re.sub(r"^import .*$", "", source, flags=re.M).replace(
                        "NoPin.ApplicationRequests.Money",
                        "NoPin.ApplicationRequests.MoneyProofControl",
                    )
                    + "\n"
                )
            text += """
open Lean Elab Command
elab "#money_control_closure" : command => do
  let env ← getEnv
  let statements := env.constants.toList.filter fun (name, _) => name.getPrefix == `NoPin.ApplicationRequests.MoneyProofControl.Statements
  let roots := statements.foldl (fun roots (_, info) => roots ++ info.type.getUsedConstants) #[]
  IO.println (Json.mkObj [("closure", toJson (NoPin.ApplicationRequests.ProofAudit.closure env roots))]).compress
#money_control_closure
"""
            path = Path(directory) / "Control.lean"
            path.write_text(text)
            log_path = ROOT / ".lake" / ("money-proof-control-" + label + ".log")
            with log_path.open("w") as log:
                result = subprocess.run(
                    [
                        "timeout",
                        "240",
                        "lake",
                        "-d",
                        str(ROOT),
                        "--keep-toolchain",
                        "env",
                        "lean",
                        str(path),
                    ],
                    stdout=log,
                    stderr=subprocess.STDOUT,
                )
            if result.returncode:
                raise ValueError(
                    "money closure control setup failed: "
                    + label
                    + "\n"
                    + "\n".join(
                        line
                        for line in log_path.read_text().splitlines()
                        if not line.startswith('{"closure"')
                    )[-5000:]
                )
            closure = next(
                json.loads(line)["closure"]
                for line in log_path.read_text().splitlines()
                if line.startswith("{")
            )
            import money_proof_check

            results[label] = money_proof_check.digest(closure)
    positive = results["positive"]
    if len(positive) < 1000 or any(
        results[label] == positive for label in results if label != "positive"
    ):
        raise ValueError("a money kernel definition substitution survived")
    return {
        "controls": [
            "changed-money-allocation",
            "changed-accepted-economic-definition",
        ],
        "detected": True,
        "constants": len(positive),
        "directSubprocesses": 3,
    }
