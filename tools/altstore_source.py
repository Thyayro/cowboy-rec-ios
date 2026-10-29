# Fonte AltStore/SideStore do Cowboy Rec: lê os releases do GitHub (IPA anexada) e escreve source.json.
# Uso (CI): python3 tools/altstore_source.py <owner/repo> <saida/source.json>   (precisa de GH_TOKEN pro gh api)
# O iPhone (AltStore/SideStore) lê esse JSON e mostra "Atualizar" quando sai versão nova.
import json, subprocess, sys, re, zipfile, plistlib, urllib.request, io, os

repo, out = sys.argv[1], sys.argv[2]
raw = f"https://raw.githubusercontent.com/{repo}/altstore"
rels = json.loads(subprocess.check_output(["gh", "api", f"repos/{repo}/releases?per_page=30"]))
versions = []
for r in rels:
    if r.get("draft"): continue
    ipa = next((a for a in r.get("assets", []) if a["name"].endswith(".ipa")), None)
    m = re.match(r"v?(\d+(?:\.\d+)+)", r["tag_name"])
    if not ipa or not m: continue
    v = {"version": m.group(1), "date": r["published_at"], "localizedDescription": r["name"] + "\n\n" + (r.get("body") or ""),
         "downloadURL": ipa["browser_download_url"], "size": ipa["size"], "minOSVersion": "17.2"}
    versions.append(v)
    if len(versions) >= 8: break
# build e versão conferidos DENTRO da IPA mais nova (nunca confiar só no nome)
if versions:
    data = urllib.request.urlopen(versions[0]["downloadURL"]).read()
    z = zipfile.ZipFile(io.BytesIO(data))
    info = plistlib.loads(z.read(next(n for n in z.namelist() if re.match(r"Payload/[^/]+\.app/Info\.plist$", n))))
    versions[0]["version"] = info["CFBundleShortVersionString"]
    versions[0]["buildVersion"] = str(info["CFBundleVersion"])
    bundle = info["CFBundleIdentifier"]
else:
    bundle = "com.cowboy.rec.personal"
for v in versions[1:]: v["buildVersion"] = "1"
app = {"name": "Cowboy Rec", "bundleIdentifier": bundle, "developerName": "Cowboy do Consórcio",
       "subtitle": "Apple Log direto na nuvem", "localizedDescription": "Câmera Apple Log que grava direto na nuvem Cowboy.",
       "iconURL": f"{raw}/icon.png", "tintColor": "#F5C518", "category": "photo-video", "versions": versions,
       "appPermissions": {"entitlements": [], "privacy": {
           "NSCameraUsageDescription": "Gravar vídeo.", "NSMicrophoneUsageDescription": "Gravar o som do vídeo.",
           "NSPhotoLibraryUsageDescription": "Mandar vídeos da galeria.", "NSPhotoLibraryAddUsageDescription": "Salvar na galeria."}}}
if versions:   # campos antigos (AltStore 1.x / SideStore antigo)
    app.update({"version": versions[0]["version"], "versionDate": versions[0]["date"], "versionDescription": versions[0]["localizedDescription"],
                "downloadURL": versions[0]["downloadURL"], "size": versions[0]["size"]})
src = {"name": "Cowboy Rec", "identifier": "com.cowboy.rec.source", "subtitle": "Versões do Cowboy Rec", "sourceURL": f"{raw}/source.json",
       "iconURL": f"{raw}/icon.png", "tintColor": "#F5C518", "apps": [app], "news": []}
os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
json.dump(src, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
print("fonte:", app.get("version"), app.get("versions") and app["versions"][0].get("buildVersion"), len(versions), "versões")
