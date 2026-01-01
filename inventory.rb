#!/usr/bin/env ruby
# Hockey Equipment Inventory System
# Focused on Jersey tracking with QR code labels

require 'webrick'
require 'json'
require 'sqlite3'
require 'securerandom'
require 'date'
require 'uri'
require 'base64'

# Database setup
DB_FILE = File.join(File.dirname(__FILE__), 'inventory.db')

def init_database
  db = SQLite3::Database.new(DB_FILE)
  db.results_as_hash = true

  # Jerseys table
  db.execute <<-SQL
    CREATE TABLE IF NOT EXISTS jerseys (
      id TEXT PRIMARY KEY,
      qty INTEGER DEFAULT 1,
      type TEXT,
      color TEXT,
      design TEXT,
      customer_name TEXT,
      number TEXT,
      size TEXT,
      namebar TEXT,
      chest_logo TEXT,
      notes TEXT,
      date_ordered TEXT,
      date_invoiced TEXT,
      date_received TEXT,
      status TEXT DEFAULT 'ordered',
      location TEXT,
      created_at TEXT,
      updated_at TEXT
    )
  SQL

  # Status history for tracking changes
  db.execute <<-SQL
    CREATE TABLE IF NOT EXISTS status_history (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      jersey_id TEXT,
      old_status TEXT,
      new_status TEXT,
      location TEXT,
      changed_at TEXT,
      notes TEXT,
      FOREIGN KEY (jersey_id) REFERENCES jerseys(id)
    )
  SQL

  # Locations table
  db.execute <<-SQL
    CREATE TABLE IF NOT EXISTS locations (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT UNIQUE,
      description TEXT
    )
  SQL

  # Add default locations if empty
  count = db.get_first_value("SELECT COUNT(*) FROM locations")
  if count == 0
    ['Warehouse', 'Office', 'Vehicle', 'Customer'].each do |loc|
      db.execute("INSERT INTO locations (name) VALUES (?)", [loc])
    end
  end

  db
end

# HTML escape helper
def h(text)
  text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
end

# Generate unique ID for jersey (used in QR code)
def generate_jersey_id
  "JRS-#{SecureRandom.hex(4).upcase}"
end

# Generate QR code as SVG (simple implementation using a library would be better, but this works)
def generate_qr_svg(data, size = 200)
  # We'll use an external QR code API for simplicity
  # In production, you'd use a gem like 'rqrcode'
  encoded = URI.encode_www_form_component(data)
  # Return an img tag that fetches from QR code API
  "<img src=\"https://api.qrserver.com/v1/create-qr-code/?size=#{size}x#{size}&data=#{encoded}\" alt=\"QR Code\" style=\"width: #{size}px; height: #{size}px;\">"
end

# Status colors
STATUS_COLORS = {
  'ordered' => '#ff9800',
  'received' => '#2196f3',
  'inventory' => '#4caf50',
  'delivered' => '#9c27b0',
  'need_remake' => '#f44336'
}

STATUS_LABELS = {
  'ordered' => 'Ordered',
  'received' => 'Received',
  'inventory' => 'In Inventory',
  'delivered' => 'Delivered',
  'need_remake' => 'Need Remake'
}

# Common layout
LAYOUT = <<-HTML
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Hockey Inventory</title>
  <style>
    * { box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      margin: 0;
      padding: 10px;
      background: #f5f5f5;
      font-size: 14px;
    }
    .container { max-width: 1200px; margin: 0 auto; }
    h1 { color: #333; margin: 0 0 15px 0; font-size: 24px; }
    h2 { color: #555; margin: 15px 0 10px 0; font-size: 18px; }

    .nav {
      background: #1976d2;
      padding: 10px;
      margin: -10px -10px 15px -10px;
      display: flex;
      gap: 15px;
      flex-wrap: wrap;
      align-items: center;
    }
    .nav a {
      color: white;
      text-decoration: none;
      padding: 8px 15px;
      border-radius: 4px;
      background: rgba(255,255,255,0.1);
    }
    .nav a:hover, .nav a.active { background: rgba(255,255,255,0.25); }
    .nav .title { font-weight: bold; font-size: 18px; margin-right: auto; }

    .card {
      background: white;
      border-radius: 8px;
      padding: 15px;
      margin-bottom: 15px;
      box-shadow: 0 1px 3px rgba(0,0,0,0.1);
    }

    table {
      width: 100%%;
      border-collapse: collapse;
      font-size: 13px;
    }
    th, td {
      padding: 8px 6px;
      text-align: left;
      border-bottom: 1px solid #eee;
    }
    th { background: #f8f9fa; font-weight: 600; white-space: nowrap; }
    tr:hover { background: #f5f5f5; }

    .btn {
      display: inline-block;
      padding: 8px 16px;
      background: #1976d2;
      color: white;
      text-decoration: none;
      border-radius: 4px;
      border: none;
      cursor: pointer;
      font-size: 14px;
    }
    .btn:hover { background: #1565c0; }
    .btn-success { background: #4caf50; }
    .btn-success:hover { background: #43a047; }
    .btn-danger { background: #f44336; }
    .btn-danger:hover { background: #e53935; }
    .btn-sm { padding: 4px 10px; font-size: 12px; }

    .status-badge {
      display: inline-block;
      padding: 3px 8px;
      border-radius: 12px;
      font-size: 11px;
      font-weight: 600;
      color: white;
    }

    .form-group {
      margin-bottom: 12px;
    }
    .form-group label {
      display: block;
      margin-bottom: 4px;
      font-weight: 500;
      color: #555;
    }
    .form-group input, .form-group select, .form-group textarea {
      width: 100%%;
      padding: 8px 10px;
      border: 1px solid #ddd;
      border-radius: 4px;
      font-size: 14px;
    }
    .form-group input:focus, .form-group select:focus, .form-group textarea:focus {
      outline: none;
      border-color: #1976d2;
    }

    .form-row {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
      gap: 10px;
    }

    .qr-label {
      border: 2px dashed #ccc;
      padding: 15px;
      text-align: center;
      background: white;
      width: 280px;
      margin: 10px auto;
    }
    .qr-label .id { font-size: 14px; font-weight: bold; margin-bottom: 10px; }
    .qr-label .info { font-size: 11px; margin-top: 10px; line-height: 1.4; }

    .status-buttons {
      display: flex;
      gap: 8px;
      flex-wrap: wrap;
      margin-top: 15px;
    }
    .status-btn {
      padding: 10px 20px;
      border: 2px solid;
      border-radius: 6px;
      background: white;
      cursor: pointer;
      font-weight: 600;
      transition: all 0.2s;
    }
    .status-btn:hover { transform: scale(1.02); }
    .status-btn.active { color: white; }

    .scan-area {
      text-align: center;
      padding: 40px 20px;
      background: #e3f2fd;
      border-radius: 8px;
      margin-bottom: 20px;
    }
    .scan-area input {
      font-size: 20px;
      padding: 15px;
      width: 100%%;
      max-width: 400px;
      text-align: center;
      border: 2px solid #1976d2;
      border-radius: 8px;
    }

    .filters {
      display: flex;
      gap: 10px;
      flex-wrap: wrap;
      align-items: center;
      margin-bottom: 15px;
    }
    .filters select, .filters input {
      padding: 8px;
      border: 1px solid #ddd;
      border-radius: 4px;
    }

    .stats {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(120px, 1fr));
      gap: 10px;
      margin-bottom: 15px;
    }
    .stat-box {
      background: white;
      padding: 15px;
      border-radius: 8px;
      text-align: center;
      box-shadow: 0 1px 3px rgba(0,0,0,0.1);
    }
    .stat-box .number { font-size: 28px; font-weight: bold; }
    .stat-box .label { font-size: 11px; color: #666; margin-top: 5px; }

    @media (max-width: 600px) {
      .form-row { grid-template-columns: 1fr; }
      table { font-size: 11px; }
      th, td { padding: 6px 4px; }
      .hide-mobile { display: none; }
    }

    @media print {
      .no-print { display: none; }
      .qr-label { border: 1px solid black; page-break-inside: avoid; }
    }
  </style>
</head>
<body>
  <div class="nav no-print">
    <span class="title">Hockey Inventory</span>
    <a href="/">Dashboard</a>
    <a href="/jerseys">Jerseys</a>
    <a href="/jerseys/new">Add Jersey</a>
    <a href="/scan">Scan QR</a>
    <a href="/labels">Print Labels</a>
  </div>
  <div class="container">
    %{content}
  </div>
</body>
</html>
HTML

# Initialize database
DB = init_database

# Create server
server = WEBrick::HTTPServer.new(
  Port: 4568,
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::INFO),
  AccessLog: [[File.open('/dev/null', 'w'), WEBrick::AccessLog::COMMON_LOG_FORMAT]]
)

# Shutdown handler
trap('INT') { server.shutdown }

# Dashboard
server.mount_proc '/' do |req, res|
  res['Content-Type'] = 'text/html'

  # Get stats
  total = DB.get_first_value("SELECT COUNT(*) FROM jerseys") || 0
  stats = {}
  STATUS_LABELS.keys.each do |status|
    stats[status] = DB.get_first_value("SELECT COUNT(*) FROM jerseys WHERE status = ?", [status]) || 0
  end

  recent = DB.execute("SELECT * FROM jerseys ORDER BY created_at DESC LIMIT 10")

  stats_html = STATUS_LABELS.map do |status, label|
    color = STATUS_COLORS[status]
    count = stats[status]
    "<div class=\"stat-box\">
      <div class=\"number\" style=\"color: #{color};\">#{count}</div>
      <div class=\"label\">#{label}</div>
    </div>"
  end.join

  recent_html = recent.map do |j|
    status_color = STATUS_COLORS[j['status']] || '#666'
    "<tr>
      <td><a href=\"/jerseys/#{j['id']}\">#{h(j['id'])}</a></td>
      <td>#{h(j['customer_name'])}</td>
      <td>#{h(j['number'])}</td>
      <td>#{h(j['size'])}</td>
      <td><span class=\"status-badge\" style=\"background: #{status_color};\">#{STATUS_LABELS[j['status']] || j['status']}</span></td>
    </tr>"
  end.join

  content = <<-HTML
    <h1>Dashboard</h1>

    <div class="stats">
      <div class="stat-box">
        <div class="number">#{total}</div>
        <div class="label">Total Jerseys</div>
      </div>
      #{stats_html}
    </div>

    <div class="card">
      <h2>Recent Jerseys</h2>
      <table>
        <thead>
          <tr>
            <th>ID</th>
            <th>Customer</th>
            <th>Number</th>
            <th>Size</th>
            <th>Status</th>
          </tr>
        </thead>
        <tbody>
          #{recent_html.empty? ? '<tr><td colspan="5">No jerseys yet. <a href="/jerseys/new">Add one</a></td></tr>' : recent_html}
        </tbody>
      </table>
    </div>
  HTML

  res.body = LAYOUT % { content: content }
end

# List jerseys
server.mount_proc '/jerseys' do |req, res|
  next if req.path != '/jerseys'  # Let other routes handle /jerseys/*

  res['Content-Type'] = 'text/html'

  query = URI.decode_www_form(req.query_string || '').to_h
  status_filter = query['status']
  location_filter = query['location']
  search = query['search']

  sql = "SELECT * FROM jerseys WHERE 1=1"
  params = []

  if status_filter && !status_filter.empty?
    sql += " AND status = ?"
    params << status_filter
  end

  if location_filter && !location_filter.empty?
    sql += " AND location = ?"
    params << location_filter
  end

  if search && !search.empty?
    sql += " AND (customer_name LIKE ? OR number LIKE ? OR id LIKE ? OR namebar LIKE ?)"
    params += ["%#{search}%"] * 4
  end

  sql += " ORDER BY created_at DESC"

  jerseys = DB.execute(sql, params)
  locations = DB.execute("SELECT name FROM locations ORDER BY name")

  # Build filters
  status_options = STATUS_LABELS.map do |s, label|
    selected = s == status_filter ? ' selected' : ''
    "<option value=\"#{s}\"#{selected}>#{label}</option>"
  end.join

  location_options = locations.map do |l|
    selected = l['name'] == location_filter ? ' selected' : ''
    "<option value=\"#{h(l['name'])}\"#{selected}>#{h(l['name'])}</option>"
  end.join

  rows = jerseys.map do |j|
    status_color = STATUS_COLORS[j['status']] || '#666'
    "<tr>
      <td><a href=\"/jerseys/#{j['id']}\">#{h(j['id'])}</a></td>
      <td>#{h(j['customer_name'])}</td>
      <td>#{h(j['number'])}</td>
      <td>#{h(j['namebar'])}</td>
      <td>#{h(j['size'])}</td>
      <td>#{h(j['color'])}</td>
      <td><span class=\"status-badge\" style=\"background: #{status_color};\">#{STATUS_LABELS[j['status']] || j['status']}</span></td>
      <td>#{h(j['location'])}</td>
      <td class=\"hide-mobile\">#{j['date_ordered']}</td>
    </tr>"
  end.join

  content = <<-HTML
    <h1>Jerseys</h1>

    <div class="card">
      <form method="get" class="filters">
        <input type="text" name="search" placeholder="Search..." value="#{h(search)}" style="flex: 1; min-width: 150px;">
        <select name="status" onchange="this.form.submit()">
          <option value="">All Statuses</option>
          #{status_options}
        </select>
        <select name="location" onchange="this.form.submit()">
          <option value="">All Locations</option>
          #{location_options}
        </select>
        <button type="submit" class="btn">Filter</button>
        <a href="/jerseys/new" class="btn btn-success">+ Add Jersey</a>
      </form>
    </div>

    <div class="card" style="overflow-x: auto;">
      <table>
        <thead>
          <tr>
            <th>ID</th>
            <th>Customer</th>
            <th>Number</th>
            <th>Namebar</th>
            <th>Size</th>
            <th>Color</th>
            <th>Status</th>
            <th>Location</th>
            <th class="hide-mobile">Ordered</th>
          </tr>
        </thead>
        <tbody>
          #{rows.empty? ? '<tr><td colspan="9">No jerseys found</td></tr>' : rows}
        </tbody>
      </table>
      <p style="color: #666; font-size: 12px; margin-top: 10px;">#{jerseys.length} jerseys</p>
    </div>
  HTML

  res.body = LAYOUT % { content: content }
end

# New jersey form
server.mount_proc '/jerseys/new' do |req, res|
  res['Content-Type'] = 'text/html'

  locations = DB.execute("SELECT name FROM locations ORDER BY name")
  location_options = locations.map { |l| "<option value=\"#{h(l['name'])}\">#{h(l['name'])}</option>" }.join

  content = <<-HTML
    <h1>Add New Jersey</h1>

    <div class="card">
      <form method="post" action="/jerseys/create">
        <div class="form-row">
          <div class="form-group">
            <label>Quantity</label>
            <input type="number" name="qty" value="1" min="1">
          </div>
          <div class="form-group">
            <label>Type</label>
            <input type="text" name="type" placeholder="e.g., Home, Away, Practice">
          </div>
          <div class="form-group">
            <label>Color</label>
            <input type="text" name="color" placeholder="e.g., Red, Blue">
          </div>
          <div class="form-group">
            <label>Design</label>
            <input type="text" name="design" placeholder="Design name/number">
          </div>
        </div>

        <div class="form-row">
          <div class="form-group">
            <label>Customer Name</label>
            <input type="text" name="customer_name" required>
          </div>
          <div class="form-group">
            <label>Number</label>
            <input type="text" name="number" placeholder="Jersey number">
          </div>
          <div class="form-group">
            <label>Size</label>
            <select name="size">
              <option value="">Select Size</option>
              <option value="YS">Youth Small</option>
              <option value="YM">Youth Medium</option>
              <option value="YL">Youth Large</option>
              <option value="YXL">Youth XL</option>
              <option value="AS">Adult Small</option>
              <option value="AM">Adult Medium</option>
              <option value="AL">Adult Large</option>
              <option value="AXL">Adult XL</option>
              <option value="A2XL">Adult 2XL</option>
              <option value="A3XL">Adult 3XL</option>
            </select>
          </div>
          <div class="form-group">
            <label>Namebar (exactly as shown)</label>
            <input type="text" name="namebar" placeholder="SMITH">
          </div>
        </div>

        <div class="form-row">
          <div class="form-group">
            <label>Over Left Chest (4") Heart Side</label>
            <input type="text" name="chest_logo" placeholder="Logo/patch description">
          </div>
          <div class="form-group">
            <label>Status</label>
            <select name="status">
              <option value="ordered">Ordered</option>
              <option value="received">Received</option>
              <option value="inventory">In Inventory</option>
            </select>
          </div>
          <div class="form-group">
            <label>Location</label>
            <select name="location">
              <option value="">Select Location</option>
              #{location_options}
            </select>
          </div>
        </div>

        <div class="form-row">
          <div class="form-group">
            <label>Date Ordered</label>
            <input type="date" name="date_ordered" value="#{Date.today}">
          </div>
          <div class="form-group">
            <label>Date Invoiced</label>
            <input type="date" name="date_invoiced">
          </div>
          <div class="form-group">
            <label>Date Received</label>
            <input type="date" name="date_received">
          </div>
        </div>

        <div class="form-group">
          <label>Notes</label>
          <textarea name="notes" rows="3" placeholder="Any additional notes..."></textarea>
        </div>

        <button type="submit" class="btn btn-success">Create Jersey</button>
        <a href="/jerseys" class="btn">Cancel</a>
      </form>
    </div>
  HTML

  res.body = LAYOUT % { content: content }
end

# Create jersey
server.mount_proc '/jerseys/create' do |req, res|
  if req.request_method == 'POST'
    body = req.body || ''
    params = URI.decode_www_form(body).to_h

    id = generate_jersey_id
    now = Time.now.strftime('%Y-%m-%d %H:%M:%S')

    DB.execute(
      "INSERT INTO jerseys (id, qty, type, color, design, customer_name, number, size, namebar, chest_logo, notes, date_ordered, date_invoiced, date_received, status, location, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [id, params['qty'].to_i, params['type'], params['color'], params['design'], params['customer_name'], params['number'], params['size'], params['namebar'], params['chest_logo'], params['notes'], params['date_ordered'], params['date_invoiced'], params['date_received'], params['status'] || 'ordered', params['location'], now, now]
    )

    # Log status creation
    DB.execute(
      "INSERT INTO status_history (jersey_id, old_status, new_status, location, changed_at, notes) VALUES (?, ?, ?, ?, ?, ?)",
      [id, nil, params['status'] || 'ordered', params['location'], now, 'Created']
    )

    res.set_redirect(WEBrick::HTTPStatus::SeeOther, "/jerseys/#{id}")
  end
end

# View single jersey
server.mount_proc '/jerseys/' do |req, res|
  # Extract ID from path
  path_parts = req.path.split('/')
  jersey_id = path_parts[2]
  action = path_parts[3]

  next unless jersey_id && !jersey_id.empty?

  # Handle different actions
  if action == 'edit'
    # Edit form
    jersey = DB.execute("SELECT * FROM jerseys WHERE id = ?", [jersey_id]).first
    unless jersey
      res.set_redirect(WEBrick::HTTPStatus::SeeOther, '/jerseys')
      next
    end

    res['Content-Type'] = 'text/html'
    locations = DB.execute("SELECT name FROM locations ORDER BY name")
    location_options = locations.map do |l|
      selected = l['name'] == jersey['location'] ? ' selected' : ''
      "<option value=\"#{h(l['name'])}\"#{selected}>#{h(l['name'])}</option>"
    end.join

    size_options = ['YS', 'YM', 'YL', 'YXL', 'AS', 'AM', 'AL', 'AXL', 'A2XL', 'A3XL'].map do |s|
      selected = s == jersey['size'] ? ' selected' : ''
      "<option value=\"#{s}\"#{selected}>#{s}</option>"
    end.join

    status_options = STATUS_LABELS.map do |s, label|
      selected = s == jersey['status'] ? ' selected' : ''
      "<option value=\"#{s}\"#{selected}>#{label}</option>"
    end.join

    content = <<-HTML
      <h1>Edit Jersey #{h(jersey_id)}</h1>

      <div class="card">
        <form method="post" action="/jerseys/#{jersey_id}/update">
          <div class="form-row">
            <div class="form-group">
              <label>Quantity</label>
              <input type="number" name="qty" value="#{jersey['qty']}" min="1">
            </div>
            <div class="form-group">
              <label>Type</label>
              <input type="text" name="type" value="#{h(jersey['type'])}">
            </div>
            <div class="form-group">
              <label>Color</label>
              <input type="text" name="color" value="#{h(jersey['color'])}">
            </div>
            <div class="form-group">
              <label>Design</label>
              <input type="text" name="design" value="#{h(jersey['design'])}">
            </div>
          </div>

          <div class="form-row">
            <div class="form-group">
              <label>Customer Name</label>
              <input type="text" name="customer_name" value="#{h(jersey['customer_name'])}" required>
            </div>
            <div class="form-group">
              <label>Number</label>
              <input type="text" name="number" value="#{h(jersey['number'])}">
            </div>
            <div class="form-group">
              <label>Size</label>
              <select name="size">
                <option value="">Select Size</option>
                #{size_options}
              </select>
            </div>
            <div class="form-group">
              <label>Namebar</label>
              <input type="text" name="namebar" value="#{h(jersey['namebar'])}">
            </div>
          </div>

          <div class="form-row">
            <div class="form-group">
              <label>Chest Logo</label>
              <input type="text" name="chest_logo" value="#{h(jersey['chest_logo'])}">
            </div>
            <div class="form-group">
              <label>Status</label>
              <select name="status">
                #{status_options}
              </select>
            </div>
            <div class="form-group">
              <label>Location</label>
              <select name="location">
                <option value="">Select Location</option>
                #{location_options}
              </select>
            </div>
          </div>

          <div class="form-row">
            <div class="form-group">
              <label>Date Ordered</label>
              <input type="date" name="date_ordered" value="#{jersey['date_ordered']}">
            </div>
            <div class="form-group">
              <label>Date Invoiced</label>
              <input type="date" name="date_invoiced" value="#{jersey['date_invoiced']}">
            </div>
            <div class="form-group">
              <label>Date Received</label>
              <input type="date" name="date_received" value="#{jersey['date_received']}">
            </div>
          </div>

          <div class="form-group">
            <label>Notes</label>
            <textarea name="notes" rows="3">#{h(jersey['notes'])}</textarea>
          </div>

          <button type="submit" class="btn btn-success">Save Changes</button>
          <a href="/jerseys/#{jersey_id}" class="btn">Cancel</a>
        </form>
      </div>
    HTML

    res.body = LAYOUT % { content: content }

  elsif action == 'update' && req.request_method == 'POST'
    # Update jersey
    body = req.body || ''
    params = URI.decode_www_form(body).to_h

    old_jersey = DB.execute("SELECT status, location FROM jerseys WHERE id = ?", [jersey_id]).first
    now = Time.now.strftime('%Y-%m-%d %H:%M:%S')

    DB.execute(
      "UPDATE jerseys SET qty=?, type=?, color=?, design=?, customer_name=?, number=?, size=?, namebar=?, chest_logo=?, notes=?, date_ordered=?, date_invoiced=?, date_received=?, status=?, location=?, updated_at=? WHERE id=?",
      [params['qty'].to_i, params['type'], params['color'], params['design'], params['customer_name'], params['number'], params['size'], params['namebar'], params['chest_logo'], params['notes'], params['date_ordered'], params['date_invoiced'], params['date_received'], params['status'], params['location'], now, jersey_id]
    )

    # Log status change if changed
    if old_jersey && old_jersey['status'] != params['status']
      DB.execute(
        "INSERT INTO status_history (jersey_id, old_status, new_status, location, changed_at) VALUES (?, ?, ?, ?, ?)",
        [jersey_id, old_jersey['status'], params['status'], params['location'], now]
      )
    end

    res.set_redirect(WEBrick::HTTPStatus::SeeOther, "/jerseys/#{jersey_id}")

  elsif action == 'status' && req.request_method == 'POST'
    # Quick status update (from scan page)
    body = req.body || ''
    params = URI.decode_www_form(body).to_h

    old_jersey = DB.execute("SELECT status, location FROM jerseys WHERE id = ?", [jersey_id]).first
    now = Time.now.strftime('%Y-%m-%d %H:%M:%S')

    new_status = params['status']
    new_location = params['location'] || old_jersey['location']

    DB.execute(
      "UPDATE jerseys SET status=?, location=?, updated_at=? WHERE id=?",
      [new_status, new_location, now, jersey_id]
    )

    DB.execute(
      "INSERT INTO status_history (jersey_id, old_status, new_status, location, changed_at, notes) VALUES (?, ?, ?, ?, ?, ?)",
      [jersey_id, old_jersey['status'], new_status, new_location, now, params['notes']]
    )

    res.set_redirect(WEBrick::HTTPStatus::SeeOther, "/jerseys/#{jersey_id}")

  elsif action == 'delete' && req.request_method == 'POST'
    DB.execute("DELETE FROM jerseys WHERE id = ?", [jersey_id])
    DB.execute("DELETE FROM status_history WHERE jersey_id = ?", [jersey_id])
    res.set_redirect(WEBrick::HTTPStatus::SeeOther, '/jerseys')

  elsif action == 'label'
    # Print label page
    jersey = DB.execute("SELECT * FROM jerseys WHERE id = ?", [jersey_id]).first
    unless jersey
      res.set_redirect(WEBrick::HTTPStatus::SeeOther, '/jerseys')
      next
    end

    res['Content-Type'] = 'text/html'

    # QR code URL - points to the jersey detail page
    base_url = "http://#{req.host}:#{req.port}"
    qr_url = "#{base_url}/jerseys/#{jersey_id}"

    content = <<-HTML
      <h1>Print Label - #{h(jersey_id)}</h1>

      <div class="no-print" style="margin-bottom: 20px;">
        <button onclick="window.print()" class="btn">Print Label</button>
        <a href="/jerseys/#{jersey_id}" class="btn">Back to Jersey</a>
      </div>

      <div class="qr-label">
        <div class="id">#{h(jersey_id)}</div>
        #{generate_qr_svg(qr_url, 150)}
        <div class="info">
          <strong>#{h(jersey['namebar'])}</strong> ##{h(jersey['number'])}<br>
          #{h(jersey['customer_name'])}<br>
          Size: #{h(jersey['size'])} | #{h(jersey['color'])}
        </div>
      </div>
    HTML

    res.body = LAYOUT % { content: content }

  else
    # View jersey
    jersey = DB.execute("SELECT * FROM jerseys WHERE id = ?", [jersey_id]).first
    unless jersey
      res.set_redirect(WEBrick::HTTPStatus::SeeOther, '/jerseys')
      next
    end

    res['Content-Type'] = 'text/html'

    history = DB.execute("SELECT * FROM status_history WHERE jersey_id = ? ORDER BY changed_at DESC", [jersey_id])
    locations = DB.execute("SELECT name FROM locations ORDER BY name")

    status_color = STATUS_COLORS[jersey['status']] || '#666'

    # Status change buttons
    status_buttons = STATUS_LABELS.map do |s, label|
      color = STATUS_COLORS[s]
      active = jersey['status'] == s ? 'active' : ''
      bg = jersey['status'] == s ? "background: #{color};" : ''
      "<button type=\"submit\" name=\"status\" value=\"#{s}\" class=\"status-btn #{active}\" style=\"border-color: #{color}; color: #{color}; #{bg}\">#{label}</button>"
    end.join

    location_options = locations.map do |l|
      selected = l['name'] == jersey['location'] ? ' selected' : ''
      "<option value=\"#{h(l['name'])}\"#{selected}>#{h(l['name'])}</option>"
    end.join

    history_rows = history.map do |h_item|
      old_label = STATUS_LABELS[h_item['old_status']] || h_item['old_status'] || 'New'
      new_label = STATUS_LABELS[h_item['new_status']] || h_item['new_status']
      "<tr>
        <td>#{h_item['changed_at']}</td>
        <td>#{h(old_label)} &rarr; #{h(new_label)}</td>
        <td>#{h(h_item['location'])}</td>
        <td>#{h(h_item['notes'])}</td>
      </tr>"
    end.join

    # QR code
    base_url = "http://#{req.host}:#{req.port}"
    qr_url = "#{base_url}/jerseys/#{jersey_id}"

    content = <<-HTML
      <h1>Jersey #{h(jersey_id)}</h1>

      <div style="display: grid; grid-template-columns: 1fr auto; gap: 20px; align-items: start;">
        <div class="card">
          <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 15px;">
            <span class="status-badge" style="background: #{status_color}; font-size: 14px; padding: 5px 12px;">
              #{STATUS_LABELS[jersey['status']] || jersey['status']}
            </span>
            <div>
              <a href="/jerseys/#{jersey_id}/edit" class="btn btn-sm">Edit</a>
              <a href="/jerseys/#{jersey_id}/label" class="btn btn-sm">Print Label</a>
            </div>
          </div>

          <table>
            <tr><th width="150">Customer</th><td><strong>#{h(jersey['customer_name'])}</strong></td></tr>
            <tr><th>Namebar</th><td><strong style="font-size: 18px;">#{h(jersey['namebar'])}</strong></td></tr>
            <tr><th>Number</th><td><strong style="font-size: 18px;">##{h(jersey['number'])}</strong></td></tr>
            <tr><th>Size</th><td>#{h(jersey['size'])}</td></tr>
            <tr><th>Type</th><td>#{h(jersey['type'])}</td></tr>
            <tr><th>Color</th><td>#{h(jersey['color'])}</td></tr>
            <tr><th>Design</th><td>#{h(jersey['design'])}</td></tr>
            <tr><th>Chest Logo</th><td>#{h(jersey['chest_logo'])}</td></tr>
            <tr><th>Quantity</th><td>#{jersey['qty']}</td></tr>
            <tr><th>Location</th><td>#{h(jersey['location']) || '-'}</td></tr>
            <tr><th>Date Ordered</th><td>#{jersey['date_ordered'] || '-'}</td></tr>
            <tr><th>Date Invoiced</th><td>#{jersey['date_invoiced'] || '-'}</td></tr>
            <tr><th>Date Received</th><td>#{jersey['date_received'] || '-'}</td></tr>
            <tr><th>Notes</th><td>#{h(jersey['notes']) || '-'}</td></tr>
          </table>
        </div>

        <div class="qr-label no-print" style="margin: 0;">
          <div class="id">#{h(jersey_id)}</div>
          #{generate_qr_svg(qr_url, 120)}
          <div class="info">Scan to view/update</div>
        </div>
      </div>

      <div class="card">
        <h2>Quick Status Update</h2>
        <form method="post" action="/jerseys/#{jersey_id}/status">
          <div class="status-buttons">
            #{status_buttons}
          </div>
          <div class="form-row" style="margin-top: 15px;">
            <div class="form-group">
              <label>Location</label>
              <select name="location">
                <option value="">Select Location</option>
                #{location_options}
              </select>
            </div>
            <div class="form-group">
              <label>Notes (optional)</label>
              <input type="text" name="notes" placeholder="Reason for change...">
            </div>
          </div>
        </form>
      </div>

      <div class="card">
        <h2>Status History</h2>
        <table>
          <thead>
            <tr>
              <th>Date</th>
              <th>Change</th>
              <th>Location</th>
              <th>Notes</th>
            </tr>
          </thead>
          <tbody>
            #{history_rows.empty? ? '<tr><td colspan="4">No history</td></tr>' : history_rows}
          </tbody>
        </table>
      </div>

      <div class="card" style="border: 2px solid #f44336;">
        <h2 style="color: #f44336;">Danger Zone</h2>
        <form method="post" action="/jerseys/#{jersey_id}/delete" onsubmit="return confirm('Delete this jersey? This cannot be undone.');">
          <button type="submit" class="btn btn-danger">Delete Jersey</button>
        </form>
      </div>
    HTML

    res.body = LAYOUT % { content: content }
  end
end

# Scan page (for mobile QR scanning)
server.mount_proc '/scan' do |req, res|
  res['Content-Type'] = 'text/html'

  query = URI.decode_www_form(req.query_string || '').to_h
  scan_id = query['id']

  # If ID provided, redirect to jersey page
  if scan_id && !scan_id.empty?
    # Extract jersey ID from URL if full URL was scanned
    if scan_id.include?('/jerseys/')
      scan_id = scan_id.split('/jerseys/').last.split('/').first.split('?').first
    end
    res.set_redirect(WEBrick::HTTPStatus::SeeOther, "/jerseys/#{scan_id}")
    return
  end

  content = <<-HTML
    <h1>Scan Jersey QR Code</h1>

    <div class="scan-area">
      <p style="margin-bottom: 20px; color: #666;">Enter Jersey ID or scan QR code:</p>
      <form method="get" action="/scan">
        <input type="text" name="id" placeholder="JRS-XXXXXXXX" autofocus
               style="text-transform: uppercase;"
               pattern=".*[A-Z0-9].*">
        <br><br>
        <button type="submit" class="btn btn-success" style="padding: 15px 40px; font-size: 18px;">Go</button>
      </form>
    </div>

    <div class="card">
      <h2>How to Use</h2>
      <ol style="line-height: 2;">
        <li>Use your phone's camera to scan a jersey QR code label</li>
        <li>Or manually enter the Jersey ID (e.g., JRS-A1B2C3D4)</li>
        <li>View and update the jersey status from the detail page</li>
      </ol>
    </div>
  HTML

  res.body = LAYOUT % { content: content }
end

# Print labels page (batch printing)
server.mount_proc '/labels' do |req, res|
  res['Content-Type'] = 'text/html'

  query = URI.decode_www_form(req.query_string || '').to_h
  status_filter = query['status']

  sql = "SELECT * FROM jerseys"
  params = []

  if status_filter && !status_filter.empty?
    sql += " WHERE status = ?"
    params << status_filter
  end

  sql += " ORDER BY created_at DESC"
  jerseys = DB.execute(sql, params)

  base_url = "http://#{req.host}:#{req.port}"

  status_options = STATUS_LABELS.map do |s, label|
    selected = s == status_filter ? ' selected' : ''
    "<option value=\"#{s}\"#{selected}>#{label}</option>"
  end.join

  labels_html = jerseys.map do |j|
    qr_url = "#{base_url}/jerseys/#{j['id']}"
    "<div class=\"qr-label\">
      <div class=\"id\">#{h(j['id'])}</div>
      #{generate_qr_svg(qr_url, 120)}
      <div class=\"info\">
        <strong>#{h(j['namebar'])}</strong> ##{h(j['number'])}<br>
        #{h(j['customer_name'])}<br>
        Size: #{h(j['size'])} | #{h(j['color'])}
      </div>
    </div>"
  end.join

  content = <<-HTML
    <h1>Print Labels</h1>

    <div class="card no-print">
      <form method="get" class="filters">
        <select name="status" onchange="this.form.submit()">
          <option value="">All Statuses</option>
          #{status_options}
        </select>
        <button type="submit" class="btn">Filter</button>
        <button type="button" onclick="window.print()" class="btn btn-success">Print All (#{jerseys.length})</button>
      </form>
    </div>

    <div style="display: flex; flex-wrap: wrap; gap: 20px; justify-content: center;">
      #{labels_html.empty? ? '<p>No jerseys to print</p>' : labels_html}
    </div>
  HTML

  res.body = LAYOUT % { content: content }
end

# API endpoint for mobile apps (optional - returns JSON)
server.mount_proc '/api/jerseys' do |req, res|
  res['Content-Type'] = 'application/json'

  if req.path =~ /\/api\/jerseys\/([^\/]+)$/
    jersey_id = $1
    jersey = DB.execute("SELECT * FROM jerseys WHERE id = ?", [jersey_id]).first
    res.body = jersey ? jersey.to_json : { error: 'Not found' }.to_json
  else
    jerseys = DB.execute("SELECT * FROM jerseys ORDER BY created_at DESC")
    res.body = jerseys.to_json
  end
end

puts "=" * 50
puts "Hockey Inventory Server"
puts "=" * 50
puts "Server running at: http://localhost:4568"
puts "Dashboard:         http://localhost:4568/"
puts "Jerseys:           http://localhost:4568/jerseys"
puts "Add Jersey:        http://localhost:4568/jerseys/new"
puts "Scan QR:           http://localhost:4568/scan"
puts "Print Labels:      http://localhost:4568/labels"
puts "=" * 50
puts "Press Ctrl+C to stop"

server.start
