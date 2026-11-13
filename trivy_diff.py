import argparse
import sys
from bs4 import BeautifulSoup
import copy

def parse_arguments():
    parser = argparse.ArgumentParser(description='Generate a delta report from two Trivy HTML scan results.')
    parser.add_argument('old_file', help='Path to the older HTML scan file')
    parser.add_argument('new_file', help='Path to the newer HTML scan file')
    parser.add_argument('-o', '--output', default='delta_report.html', help='Path to the output HTML file')
    return parser.parse_args()

def load_html(filepath):
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            return BeautifulSoup(f, 'html.parser')
    except Exception as e:
        print(f"Error loading {filepath}: {e}")
        sys.exit(1)

def get_row_data(row):
    """
    Extracts key data from a row for identification.
    Returns tuple: (package_name, vulnerability_id, installed_version)
    """
    cols = row.find_all('td')
    if len(cols) < 4: # Need at least package, vuln, severity, installed
        return None
        
    pkg_name = cols[0].get_text(strip=True)
    vuln_id = cols[1].get_text(strip=True)
    # Some items might have same pkg + vuln but different version (rare but possible in some contexts)
    # Adding installed version helps uniqueness.
    installed_version = cols[3].get_text(strip=True)
    
    return (pkg_name, vuln_id, installed_version)

def extract_vulnerabilities_with_context(soup):
    """
    Extracts vulnerability rows from the soup along with their group header context.
    Returns a list of objects: 
    [
      {
        'header': "redhat",
        'rows': [
           { 'key': (pkg, vuln_id, installed_ver), 'row': soup_element },
           ...
        ]
      },
      ...
    ]
    
    Also returns a flat dict for easy lookup: { (pkg, vuln_id, installed_ver): row_element }
    """
    
    structure = []
    flat_vulns = {}
    
    table = soup.find('table')
    if not table:
        return structure, flat_vulns

    current_group = "Unknown"
    current_rows = []
    
    # Iterate over all tr elements in the table
    for tr in table.find_all('tr'):
        # Check if it's a group header
        if 'class' in tr.attrs and 'group-header' in tr.attrs['class']:
            # If we have a previous group with rows, save it
            if current_rows:
                structure.append({'header': current_group, 'rows': current_rows})
                current_rows = []
            
            # Update current group name
            current_group = tr.get_text(strip=True)
            
        # Check if it's a severity row (actual data)
        elif 'class' in tr.attrs and any(c.startswith('severity-') for c in tr.attrs['class']):
            key_data = get_row_data(tr)
            if key_data:
                pkg_name, vuln_id, installed_ver = key_data
                
                # Normalize key (strip whitespace, maybe lower case if needed?)
                # Usually package names and IDs are case-sensitive or standard, but whitespace can be an issue.
                # We already strip whitespace in get_row_data.
                
                # Include Group Name in key? 
                # Sometimes same package appears in different targets (e.g. OS pkgs vs Python pkgs)
                # If the group header is different, they are effectively different findings.
                full_key = (current_group, pkg_name, vuln_id, installed_ver)
                
                # Add to flat dict
                flat_vulns[full_key] = tr
                
                # Add to current group list
                current_rows.append({'key': full_key, 'row': tr})
                
    # Append the last group if it has rows
    if current_rows:
        structure.append({'header': current_group, 'rows': current_rows})
        
    return structure, flat_vulns

def create_header_row(soup, text, color_class="group-header"):
    """Creates a header row spanning the table columns."""
    tr = soup.new_tag("tr", attrs={"class": color_class})
    th = soup.new_tag("th", attrs={"colspan": "6", "style": "background-color: #ddd; text-align: center;"})
    th.string = text
    tr.append(th)
    return tr

def main():
    args = parse_arguments()
    
    print(f"Loading old file: {args.old_file}")
    soup_old = load_html(args.old_file)
    
    print(f"Loading new file: {args.new_file}")
    soup_new = load_html(args.new_file)
    
    # Extract data with structural context
    structure_old, vulns_old = extract_vulnerabilities_with_context(soup_old)
    structure_new, vulns_new = extract_vulnerabilities_with_context(soup_new)
    
    print(f"Found {len(vulns_old)} vulnerabilities in old file.")
    print(f"Found {len(vulns_new)} vulnerabilities in new file.")
    
    # Calculate Delta
    old_keys = set(vulns_old.keys())
    new_keys = set(vulns_new.keys())
    
    added_keys = new_keys - old_keys
    removed_keys = old_keys - new_keys
    
    print(f"New vulnerabilities: {len(added_keys)}")
    print(f"Resolved vulnerabilities: {len(removed_keys)}")
    
    # Prepare Output
    output_soup = copy.copy(soup_new)
    table = output_soup.find('table')
    if not table:
        print("Error: Could not find <table> in the new file.")
        sys.exit(1)
    
    # Clear existing content from table but keep the structure we want to build
    # We'll rebuild the table content completely
    table.clear()
    
    # 1. Render NEWLY DETECTED vulnerabilities
    if added_keys:
        main_header = create_header_row(output_soup, f"NEWLY DETECTED ({len(added_keys)})", "group-header")
        main_header.find('th')['style'] = "background-color: #ffcccc; text-align: center; font-weight: bold;"
        table.append(main_header)
        
        for group in structure_new:
            group_added_rows = [r for r in group['rows'] if r['key'] in added_keys]
            
            if group_added_rows:
                # Add the group header
                gh = create_header_row(output_soup, group['header'], "group-header")
                table.append(gh)
                
                # Add sub-header
                sub_header_orig = soup_new.find('tr', class_='sub-header')
                if sub_header_orig:
                    table.append(copy.copy(sub_header_orig))
                
                # Add the rows
                for item in group_added_rows:
                    new_row = copy.copy(item['row'])
                    table.append(new_row)

    # 2. Render RESOLVED vulnerabilities
    if removed_keys:
        main_header = create_header_row(output_soup, f"RESOLVED / REMOVED ({len(removed_keys)})", "group-header")
        main_header.find('th')['style'] = "background-color: #ccffcc; text-align: center; font-weight: bold;"
        table.append(main_header)
        
        for group in structure_old:
            group_removed_rows = [r for r in group['rows'] if r['key'] in removed_keys]
            
            if group_removed_rows:
                # Add the group header
                gh = create_header_row(output_soup, group['header'], "group-header")
                table.append(gh)
                
                # Add sub-header
                sub_header_orig = soup_old.find('tr', class_='sub-header')
                if sub_header_orig:
                    table.append(copy.copy(sub_header_orig))
                
                # Add the rows
                for item in group_removed_rows:
                    new_row = copy.copy(item['row'])
                    
                    # Style as removed
                    if 'style' in new_row.attrs:
                        new_row['style'] += "; opacity: 0.6; text-decoration: line-through;"
                    else:
                        new_row['style'] = "opacity: 0.6;"
                        
                    table.append(new_row)

    # Modify metadata
    h1 = output_soup.find('h1')
    if h1:
        h1.string = f"Delta Report: {h1.get_text()}"
        
    title = output_soup.find('title')
    if title:
        title.string = f"Delta Report: {title.get_text()}"

    # Write output
    with open(args.output, 'w', encoding='utf-8') as f:
        f.write(str(output_soup))
        
    print(f"Report generated: {args.output}")

if __name__ == "__main__":
    main()
