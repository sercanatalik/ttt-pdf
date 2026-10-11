"""Writes the test fixtures in tests/fixtures/:

- sample.pdf: three letter-size pages titled Alpha, Bravo, Charlie
- short.pdf: two pages, Delta and Echo (the "rebuilt" document in the auto-reload test)
- mixed.pdf: a portrait page, a landscape page, and a portrait page rotated 90 degrees
- encrypted.pdf: one page that needs the user password "secret" (40-bit RC4, standard security handler)
"""
import hashlib
import pathlib

LETTER = (612, 792)
LANDSCAPE = (792, 612)

FIXTURES = {
    "sample.pdf": [("Alpha page", LETTER, 0), ("Bravo page", LETTER, 0), ("Charlie page", LETTER, 0)],
    "short.pdf": [("Delta page", LETTER, 0), ("Echo page", LETTER, 0)],
    "mixed.pdf": [("Portrait page", LETTER, 0), ("Landscape page", LANDSCAPE, 0), ("Rotated page", LETTER, 90)],
    "encrypted.pdf": [("Secret page", LETTER, 0)],
}
ENCRYPTED = {"encrypted.pdf": ("secret", "owner")}

PAD = bytes.fromhex("28bf4e5e4e758a4164004e56fffa01082e2e00b6d0683e802f0ca9fe6453697a")
FILE_ID = bytes.fromhex("7474742d706466207465737420666978")


def rc4(key, data):
    s = list(range(256))
    j = 0
    for i in range(256):
        j = (j + s[i] + key[i % len(key)]) % 256
        s[i], s[j] = s[j], s[i]
    out = bytearray()
    i = j = 0
    for byte in data:
        i = (i + 1) % 256
        j = (j + s[i]) % 256
        s[i], s[j] = s[j], s[i]
        out.append(byte ^ s[(s[i] + s[j]) % 256])
    return bytes(out)


def padded(password):
    return (password.encode() + PAD)[:32]


def security(user, owner, permissions=-44):
    """Standard security handler, revision 2: returns the file key and the /Encrypt dictionary."""
    o_entry = rc4(hashlib.md5(padded(owner)).digest()[:5], padded(user))
    p_bytes = permissions.to_bytes(4, "little", signed=True)
    key = hashlib.md5(padded(user) + o_entry + p_bytes + FILE_ID).digest()[:5]
    u_entry = rc4(key, PAD)
    encrypt = b"<< /Filter /Standard /V 1 /R 2 /O <%s> /U <%s> /P %d >>" % (o_entry.hex().encode(), u_entry.hex().encode(), permissions)
    return key, encrypt


def object_key(key, num):
    return hashlib.md5(key + num.to_bytes(3, "little") + (0).to_bytes(2, "little")).digest()[:10]


def build(pages, passwords=None):
    key = encrypt_dict = None
    if passwords:
        key, encrypt_dict = security(*passwords)

    objs = {1: b"<< /Type /Catalog /Pages 2 0 R >>", 3: b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"}
    kids = []
    num = 4
    for title, (w, h), rotate in pages:
        text = f"BT /F1 36 Tf 72 {h - 92} Td ({title}) Tj 0 -60 Td /F1 14 Tf (Rendered by the ttt pdf-viewer test suite.) Tj ET".encode()
        if key:
            text = rc4(object_key(key, num), text)
        objs[num] = b"<< /Length %d >>\nstream\n" % len(text) + text + b"\nendstream"
        rot = b" /Rotate %d" % rotate if rotate else b""
        objs[num + 1] = b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %d %d]%s /Contents %d 0 R /Resources << /Font << /F1 3 0 R >> >> >>" % (w, h, rot, num)
        kids.append(num + 1)
        num += 2
    objs[2] = b"<< /Type /Pages /Kids [%s] /Count %d >>" % (b" ".join(b"%d 0 R" % k for k in kids), len(kids))
    if encrypt_dict:
        objs[num] = encrypt_dict

    out = b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n"
    offsets = {}
    for i in sorted(objs):
        offsets[i] = len(out)
        out += b"%d 0 obj\n" % i + objs[i] + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    for i in sorted(objs):
        out += b"%010d 00000 n \n" % offsets[i]
    trailer = b"/Size %d /Root 1 0 R" % (len(objs) + 1)
    if encrypt_dict:
        trailer += b" /Encrypt %d 0 R /ID [<%s> <%s>]" % (num, FILE_ID.hex().encode(), FILE_ID.hex().encode())
    out += b"trailer\n<< %s >>\nstartxref\n%d\n%%%%EOF\n" % (trailer, xref)
    return out


if __name__ == "__main__":
    for name, pages in FIXTURES.items():
        path = pathlib.Path(__file__).parent / "fixtures" / name
        path.write_bytes(build(pages, ENCRYPTED.get(name)))
        print(path)
