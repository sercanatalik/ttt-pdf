"""Writes tests/fixtures/sample.pdf: three letter-size pages titled Alpha, Bravo, Charlie."""
import pathlib

TITLES = ["Alpha page", "Bravo page", "Charlie page"]


def build():
    objs = {1: b"<< /Type /Catalog /Pages 2 0 R >>", 3: b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"}
    kids = []
    num = 4
    for title in TITLES:
        text = f"BT /F1 36 Tf 72 700 Td ({title}) Tj 0 -60 Td /F1 14 Tf (Rendered by the ttt pdf-viewer test suite.) Tj ET".encode()
        objs[num] = b"<< /Length %d >>\nstream\n" % len(text) + text + b"\nendstream"
        objs[num + 1] = b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents %d 0 R /Resources << /Font << /F1 3 0 R >> >> >>" % num
        kids.append(num + 1)
        num += 2
    objs[2] = b"<< /Type /Pages /Kids [%s] /Count %d >>" % (b" ".join(b"%d 0 R" % k for k in kids), len(kids))

    out = b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n"
    offsets = {}
    for i in sorted(objs):
        offsets[i] = len(out)
        out += b"%d 0 obj\n" % i + objs[i] + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    for i in sorted(objs):
        out += b"%010d 00000 n \n" % offsets[i]
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
    return out


if __name__ == "__main__":
    path = pathlib.Path(__file__).parent / "fixtures" / "sample.pdf"
    path.write_bytes(build())
    print(path)
