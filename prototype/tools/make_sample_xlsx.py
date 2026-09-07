# 生成示例课表 xlsx（零依赖，仅标准库 zipfile + 手写最小 OOXML）
import os, zipfile

OUT = os.path.join(os.path.dirname(__file__), '..', 'sample_files')
os.makedirs(OUT, exist_ok=True)

def esc(s):
    return str(s).replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')

rows = [
    ['课程名称', '教师', '地点', '星期', '开始时间', '结束时间', '起始周', '结束周', '单双周'],
    ['高等数学', '张老师', '教1-201', '一', '08:00', '09:40', 1, 16, '单双'],
    ['大学英语', '李老师', '外语楼305', '一', '10:00', '11:40', 1, 16, '单'],
    ['体育', '', '操场', '二', '14:00', '15:40', 1, 16, '双'],
    ['信号与系统', '王老师', '教2-508', '三', '08:00', '09:40', 1, 16, '单双'],
    ['数据结构', '陈老师', '实验楼B204', '三', '14:00', '15:40', 1, 16, '单'],
    ['马克思主义原理', '', '教3-101', '四', '10:00', '11:40', 1, 16, '单双'],
    ['Python 程序设计', '刘老师', '机房302', '五', '14:00', '15:40', 1, 16, '双'],
]

def sheet_xml():
    rows_xml = []
    for r, row in enumerate(rows, 1):
        cells = []
        for c, v in enumerate(row, 1):
            ref = f'{chr(64 + c)}{r}'
            if isinstance(v, (int, float)):
                cells.append(f'<c r="{ref}"><v>{v}</v></c>')
            else:
                cells.append(f'<c r="{ref}" t="inlineStr"><is><t>{esc(v)}</t></is></c>')
        rows_xml.append(f'<row r="{r}">{"".join(cells)}</row>')
    return ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
            '<sheetData>' + ''.join(rows_xml) + '</sheetData></worksheet>')

files = {
    '[Content_Types].xml': ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '</Types>'),
    '_rels/.rels': ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>'),
    'xl/workbook.xml': ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets><sheet name="课表" sheetId="1" r:id="rId1"/></sheets></workbook>'),
    'xl/_rels/workbook.xml.rels': ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
        '</Relationships>'),
    'xl/worksheets/sheet1.xml': sheet_xml(),
}

path = os.path.join(OUT, '课表示例.xlsx')
with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
    for name, content in files.items():
        z.writestr(name, content)
print('written', path)
