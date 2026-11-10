#!/usr/bin/env python3
"""Builds the App Store edition of the (web-based) ChargeCheck app into ../www/index.html.

  cd web-src && npm ci && python3 build.py

Everything (the app, the text reader, the PDF tools and the English language data)
is packed into one file, so the app works with no internet.
"""
import base64, datetime, json, os, subprocess, zoneinfo

TEST_BUILD = True  # !!! set to False before 'Add for Review' – shows a free 'test mode' button in the iPhone app
AD_REWARDED = 'ca-app-pub-2905482277981262/8963561619'  # AdMob rewarded ad unit (Scan reward)
PRIVACY_URL = 'https://tlegendary.github.io/privacy.html'
APP_VERSION = '1.0'

here = os.path.dirname(os.path.abspath(__file__))
os.chdir(here)
nm = 'node_modules/'
read = lambda p: open(p).read()
main = read(nm + 'tesseract.js/dist/tesseract.min.js')
pdfmain = read(nm + 'pdfjs-dist/build/pdf.min.js')
pdfworker = read(nm + 'pdfjs-dist/build/pdf.worker.min.js')
core = read(nm + 'tesseract.js-core/tesseract-core-lstm.wasm.js')
worker = read(nm + 'tesseract.js/dist/worker.min.js')
jspdf = read(nm + 'jspdf/dist/jspdf.umd.min.js') + '\n' + read(nm + 'jspdf-autotable/dist/jspdf.plugin.autotable.min.js') + '\n' + read(nm + 'fflate/umd/index.js')
lang = base64.b64encode(open(nm + '@tesseract.js-data/eng/4.0.0_best_int/eng.traineddata.gz', 'rb').read()).decode()
shim = '''self.__LANG_B64="''' + lang + '''";
(function(){var of=self.fetch;self.fetch=function(u,o){if(String(u).indexOf("traineddata")>-1){var b=atob(self.__LANG_B64),a=new Uint8Array(b.length);for(var i=0;i<b.length;i++)a[i]=b.charCodeAt(i);return Promise.resolve(new Response(a));}return of.apply(self,arguments);};})();
'''

def js(s):
    return json.dumps(s).replace('</', '<\\/')

def minify(code):
    r = subprocess.run(['npx', 'terser', '--compress', '--mangle', '--toplevel'], input=code, capture_output=True, text=True, check=True)
    return r.stdout

html = read('index.html').replace('%%DEMO_IMG%%', 'data:image/jpeg;base64,' + read('demo_invoice.b64').strip())
a = html.index('<script>\n"use strict";') + len('<script>\n')
b = html.index('</script>', a)
app = html[a:b]
stamp = datetime.datetime.now(zoneinfo.ZoneInfo('Europe/London')).strftime('%d %b %H:%M')
boot = minify('(()=>{' + ('window.__TEST_BUILD=true;' if TEST_BUILD else '') + (f'window.__AD_REWARDED="{AD_REWARDED}";' if AD_REWARDED else '')
              + ('window.__ADS_TEST=true;' if TEST_BUILD else '')
              + f'window.__PRIVACY_URL="{PRIVACY_URL}";window.__APP_VERSION="{APP_VERSION}";window.__BUILD_STAMP="{stamp}";\n'
              + read('boot-appstore.js') + '\n})();')
html = html[:a] + boot + '</script>\n<script>' + minify('(()=>{' + app + '\n})();') + html[b:]
block = ('<script>' + main + '</script>\n<script>' + jspdf.replace('</script', '<\\/script') + '</script>\n<script>' + pdfmain + '</script>\n<script>window.__PDF_WORKER_SRC=' + js(pdfworker) + ';</script>\n'
         '<script>window.__TESS_WORKER_SRC=' + js(shim + core + '\n;\n' + worker) + ';</script>\n' + '<script>window.__SEED=null;</script>\n')
html = html.replace('<!--INLINE_TESS-->', block)
out = os.path.join(here, '..', 'www', 'index.html')
open(out, 'w').write(html)
print('www/index.html', round(len(html) / 1e6, 2), 'MB')
