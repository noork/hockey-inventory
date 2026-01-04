#!/usr/bin/env ruby
# encoding: UTF-8
# Hockey Equipment Inventory System
# Focused on Jersey tracking with QR code labels

require 'webrick'
require 'json'
require 'sqlite3'
require 'securerandom'
require 'date'
require 'uri'
require 'base64'
require 'csv'

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
      team TEXT,
      number TEXT,
      size TEXT,
      age_group TEXT DEFAULT 'Adult',
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

  # Add new columns if they don't exist (for existing databases)
  begin
    db.execute("ALTER TABLE jerseys ADD COLUMN team TEXT")
  rescue SQLite3::SQLException
    # Column already exists
  end
  begin
    db.execute("ALTER TABLE jerseys ADD COLUMN age_group TEXT DEFAULT 'Adult'")
  rescue SQLite3::SQLException
    # Column already exists
  end
  begin
    db.execute("ALTER TABLE jerseys ADD COLUMN needs_remake INTEGER DEFAULT 0")
  rescue SQLite3::SQLException
    # Column already exists
  end
  begin
    db.execute("ALTER TABLE jerseys ADD COLUMN payment_status TEXT DEFAULT 'unpaid'")
  rescue SQLite3::SQLException
    # Column already exists
  end
  begin
    db.execute("ALTER TABLE jerseys ADD COLUMN tracking_number TEXT")
  rescue SQLite3::SQLException
    # Column already exists
  end
  begin
    db.execute("ALTER TABLE jerseys ADD COLUMN date_delivered TEXT")
  rescue SQLite3::SQLException
    # Column already exists
  end
  # Set defaults for existing records
  db.execute("UPDATE jerseys SET age_group = 'Adult' WHERE age_group IS NULL OR age_group = ''")
  db.execute("UPDATE jerseys SET needs_remake = 0 WHERE needs_remake IS NULL")
  db.execute("UPDATE jerseys SET payment_status = 'unpaid' WHERE payment_status IS NULL OR payment_status = ''")

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
  text.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '').gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
end

# Render layout with proper encoding
def render_layout(content)
  result = LAYOUT % { content: content.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '') }
  result.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
end

# Convert date from MM/DD/YYYY to YYYY-MM-DD for HTML date input
def date_to_html(date_str)
  return '' if date_str.nil? || date_str.empty?
  if date_str =~ %r{^(\d{1,2})/(\d{1,2})/(\d{4})$}
    "#{$3}-#{$1.rjust(2,'0')}-#{$2.rjust(2,'0')}"
  else
    date_str
  end
end

# Extract age group from size prefix (Y = Youth, A = Adult)
# Returns [size_without_prefix, age_group]
def normalize_size(size_str)
  return ['', 'Adult'] if size_str.nil? || size_str.to_s.strip.empty?

  size = size_str.to_s.strip.upcase
  age_group = 'Adult'

  # Extract age group prefix if present
  if size.start_with?('Y')
    age_group = 'Youth'
    size = size[1..-1] if size.length > 1 # Remove Y prefix
  elsif size.start_with?('A')
    age_group = 'Adult'
    size = size[1..-1] if size.length > 1 # Remove A prefix
  end

  # Return size as-is (no normalization, keep XXL format)
  [size, age_group]
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
  'delivered' => 'Delivered'
}

PAYMENT_STATUS_LABELS = {
  'unpaid' => 'Unpaid',
  'invoiced' => 'Invoiced',
  'partial' => 'Partial',
  'paid' => 'Paid',
  'not_required' => 'No Payment Required'
}

PAYMENT_STATUS_COLORS = {
  'unpaid' => '#f44336',
  'invoiced' => '#ff9800',
  'partial' => '#2196f3',
  'paid' => '#4caf50',
  'not_required' => '#9e9e9e'
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
    <a href="/">All Jerseys</a>
    <a href="/jerseys/new">+ Add New</a>
    <a href="/scan">Scan QR</a>
    <a href="/labels">Print Labels</a>
    <a href="/locations">Locations</a>
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

# Dashboard - Main integrated view
server.mount_proc '/' do |req, res|
  res['Content-Type'] = 'text/html; charset=utf-8'

  # Parse query params for filtering and sorting
  query = URI.decode_www_form(req.query_string || '').to_h
  status_filter = query['status']
  search = query['search']
  sort_col = query['sort']
  sort_dir = query['dir'] == 'asc' ? 'ASC' : 'DESC'

  # Valid columns for sorting (whitelist to prevent SQL injection)
  valid_columns = {
    'id' => 'id', 'qty' => 'qty', 'type' => 'type', 'design' => 'design',
    'team' => 'team', 'customer' => 'customer_name', 'number' => 'number',
    'namebar' => 'namebar', 'age' => 'age_group', 'size' => 'size',
    'color' => 'color', 'status' => 'status', 'payment' => 'payment_status',
    'ordered' => 'date_ordered', 'created' => 'created_at'
  }
  order_column = valid_columns[sort_col] || 'created_at'
  default_dir = sort_col ? sort_dir : 'DESC'

  # Get stats
  total = DB.get_first_value("SELECT COUNT(*) FROM jerseys") || 0
  stats = {}
  STATUS_LABELS.keys.each do |status|
    stats[status] = DB.get_first_value("SELECT COUNT(*) FROM jerseys WHERE status = ?", [status]) || 0
  end

  # Build query for jersey list
  sql = "SELECT * FROM jerseys WHERE 1=1"
  params = []

  if status_filter && !status_filter.empty?
    sql += " AND status = ?"
    params << status_filter
  end

  if search && !search.empty?
    sql += " AND (customer_name LIKE ? OR number LIKE ? OR id LIKE ? OR namebar LIKE ? OR notes LIKE ?)"
    params += ["%#{search}%"] * 5
  end

  sql += " ORDER BY #{order_column} #{default_dir}"
  jerseys = DB.execute(sql, params)

  # Helper to build sort link URL
  build_sort_url = lambda do |col|
    new_dir = (sort_col == col && default_dir == 'DESC') ? 'asc' : 'desc'
    url_params = ["sort=#{col}", "dir=#{new_dir}"]
    url_params << "status=#{status_filter}" if status_filter && !status_filter.empty?
    url_params << "search=#{URI.encode_www_form_component(search)}" if search && !search.empty?
    "/?#{url_params.join('&')}"
  end

  # Helper to get sort arrow
  sort_arrow = lambda { |col| sort_col == col ? (default_dir == 'DESC' ? ' ▼' : ' ▲') : '' }

  # Stats with clickable filters
  stats_html = STATUS_LABELS.map do |status, label|
    color = STATUS_COLORS[status]
    count = stats[status]
    active = status_filter == status ? 'active' : ''
    "<a href=\"/?status=#{status}\" class=\"stat-box #{active}\" style=\"text-decoration: none; #{status_filter == status ? "border: 3px solid #{color};" : ''}\">
      <div class=\"number\" style=\"color: #{color};\">#{count}</div>
      <div class=\"label\">#{label}</div>
    </a>"
  end.join

  # Jersey table with more details and notes indicator
  rows_html = jerseys.map do |j|
    status_color = STATUS_COLORS[j['status']] || '#666'
    payment_color = PAYMENT_STATUS_COLORS[j['payment_status']] || '#666'
    has_notes = j['notes'] && !j['notes'].to_s.strip.empty?
    notes_icon = has_notes ? '<span title="Has notes" style="color: #ff9800; margin-left: 4px;">&#9998;</span>' : ''
    date_display = j['date_ordered'] ? j['date_ordered'].to_s.gsub(/^(\d{4})-(\d{2})-(\d{2})$/, '\2/\3/\1') : '-'
    age_display = j['age_group'] == 'Youth' ? '<span style="color: #9c27b0; font-weight: bold;">Y</span>' : 'A'
    remake_icon = j['needs_remake'].to_i == 1 ? '<span title="Needs Remake" style="color: #f44336; font-weight: bold;">!</span>' : ''

    "<tr>
      <td onclick=\"event.stopPropagation();\"><input type=\"checkbox\" name=\"ids[]\" value=\"#{h(j['id'])}\" class=\"jersey-checkbox\" style=\"width: 18px; height: 18px; cursor: pointer;\"></td>
      <td onclick=\"window.location='/jerseys/#{j['id']}'\" style=\"cursor: pointer;\"><strong>#{h(j['id'])}</strong>#{remake_icon}</td>
      <td onclick=\"window.location='/jerseys/#{j['id']}'\" style=\"cursor: pointer;\">#{j['qty'].to_i > 1 ? "<strong>#{j['qty']}</strong>" : j['qty'].to_s}</td>
      <td onclick=\"window.location='/jerseys/#{j['id']}'\" style=\"cursor: pointer;\">#{h(j['type'])}</td>
      <td onclick=\"window.location='/jerseys/#{j['id']}'\" style=\"cursor: pointer;\">#{h(j['design'])}</td>
      <td onclick=\"window.location='/jerseys/#{j['id']}'\" style=\"cursor: pointer;\">#{h(j['team'])}</td>
      <td onclick=\"window.location='/jerseys/#{j['id']}'\" style=\"cursor: pointer;\">#{h(j['customer_name'])}#{notes_icon}</td>
      <td onclick=\"window.location='/jerseys/#{j['id']}'\" style=\"cursor: pointer;\"><strong style=\"font-size: 16px;\">##{h(j['number'])}</strong></td>
      <td onclick=\"window.location='/jerseys/#{j['id']}'\" style=\"cursor: pointer;\">#{h(j['namebar'])}</td>
      <td onclick=\"window.location='/jerseys/#{j['id']}'\" style=\"cursor: pointer;\">#{age_display}</td>
      <td onclick=\"window.location='/jerseys/#{j['id']}'\" style=\"cursor: pointer;\">#{h(j['size'])}</td>
      <td onclick=\"window.location='/jerseys/#{j['id']}'\" style=\"cursor: pointer;\">#{h(j['color'])}</td>
      <td onclick=\"window.location='/jerseys/#{j['id']}'\" style=\"cursor: pointer;\"><span class=\"status-badge\" style=\"background: #{status_color};\">#{STATUS_LABELS[j['status']] || j['status']}</span></td>
      <td onclick=\"window.location='/jerseys/#{j['id']}'\" style=\"cursor: pointer;\"><span class=\"status-badge\" style=\"background: #{payment_color};\">#{PAYMENT_STATUS_LABELS[j['payment_status']] || 'Unpaid'}</span></td>
      <td onclick=\"window.location='/jerseys/#{j['id']}'\" style=\"cursor: pointer;\">#{date_display}</td>
      <td>
        <a href=\"/jerseys/#{j['id']}/edit\" class=\"btn btn-sm\" onclick=\"event.stopPropagation();\">Edit</a>
        <a href=\"/jerseys/#{j['id']}/label\" class=\"btn btn-sm\" onclick=\"event.stopPropagation();\" style=\"background: #9c27b0;\">QR</a>
      </td>
    </tr>"
  end.join

  filter_status = status_filter ? " - #{STATUS_LABELS[status_filter]}" : ''

  content = <<-HTML
    <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 15px;">
      <h1 style="margin: 0;">Jersey Inventory#{filter_status}</h1>
      <div style="display: flex; gap: 10px;">
        <a href="/jerseys/new" class="btn btn-success" style="font-size: 16px; padding: 12px 24px;">+ Add Jersey</a>
        <button onclick="document.getElementById('uploadModal').style.display='flex'" class="btn" style="font-size: 16px; padding: 12px 24px; background: #ff9800;">Upload CSV</button>
      </div>
    </div>

    <!-- Stats Row - Clickable Filters -->
    <div class="stats">
      <a href="/" class="stat-box #{status_filter.nil? || status_filter.empty? ? 'active' : ''}" style="text-decoration: none; #{status_filter.nil? || status_filter.empty? ? 'border: 3px solid #333;' : ''}">
        <div class="number">#{total}</div>
        <div class="label">All Jerseys</div>
      </a>
      #{stats_html}
    </div>

    <!-- Search and Actions Bar -->
    <div class="card" style="padding: 10px 15px;">
      <form method="get" style="display: flex; gap: 10px; align-items: center; flex-wrap: wrap;">
        <input type="hidden" name="status" value="#{h(status_filter)}">
        <input type="text" name="search" placeholder="Search customer, number, namebar, notes..." value="#{h(search)}" style="flex: 1; min-width: 200px; padding: 10px;">
        <button type="submit" class="btn">Search</button>
        #{search && !search.empty? ? '<a href="/' + (status_filter ? "?status=#{status_filter}" : '') + '" class="btn" style="background: #666;">Clear</a>' : ''}
        <span style="color: #666; margin-left: auto;">#{jerseys.length} jerseys</span>
      </form>
    </div>

    <!-- Jersey Table -->
    <form id="bulkForm" method="post" action="/jerseys/bulk-delete" onsubmit="return handleBulkSubmit(event);">
      <input type="hidden" name="bulk_action" id="bulk_action" value="delete">
      <div id="bulkActions" style="display: none; background: #fff3e0; padding: 15px; border-radius: 4px; margin-bottom: 10px; border: 1px solid #ff9800;">
        <div style="display: flex; align-items: center; gap: 10px; flex-wrap: wrap; margin-bottom: 10px;">
          <strong><span id="selectedCount">0</span> selected</strong>
          <button type="button" class="btn btn-sm" style="background: #666;" onclick="clearSelection()">Clear Selection</button>
        </div>
        <div style="display: flex; gap: 15px; flex-wrap: wrap; align-items: flex-end;">
          <div style="flex: 1; min-width: 150px;">
            <label style="display: block; font-size: 12px; margin-bottom: 4px; color: #555;">Status</label>
            <select name="bulk_status" id="bulk_status" style="width: 100%; padding: 8px; border: 1px solid #ddd; border-radius: 4px;">
              <option value="">-- No change --</option>
              <option value="ordered">Ordered</option>
              <option value="received">Received</option>
              <option value="inventory">In Inventory</option>
              <option value="delivered">Delivered</option>
            </select>
          </div>
          <div style="flex: 1; min-width: 150px;">
            <label style="display: block; font-size: 12px; margin-bottom: 4px; color: #555;">Payment Status</label>
            <select name="bulk_payment_status" id="bulk_payment_status" style="width: 100%; padding: 8px; border: 1px solid #ddd; border-radius: 4px;">
              <option value="">-- No change --</option>
              <option value="unpaid">Unpaid</option>
              <option value="invoiced">Invoiced</option>
              <option value="partial">Partial</option>
              <option value="paid">Paid</option>
              <option value="not_required">No Payment Required</option>
            </select>
          </div>
          <div style="flex: 1; min-width: 150px;">
            <label style="display: block; font-size: 12px; margin-bottom: 4px; color: #555;">Tracking Number</label>
            <input type="text" name="bulk_tracking_number" id="bulk_tracking_number" placeholder="Enter tracking #..." style="width: 100%; padding: 8px; border: 1px solid #ddd; border-radius: 4px; box-sizing: border-box;">
          </div>
          <div style="flex: 1; min-width: 150px;">
            <label style="display: block; font-size: 12px; margin-bottom: 4px; color: #555;">Date Delivered</label>
            <input type="date" name="bulk_date_delivered" id="bulk_date_delivered" style="width: 100%; padding: 8px; border: 1px solid #ddd; border-radius: 4px; box-sizing: border-box;">
          </div>
          <button type="button" class="btn btn-success btn-sm" onclick="submitBulkUpdate()" style="padding: 8px 20px;">Update Selected</button>
          <button type="button" class="btn btn-danger btn-sm" onclick="submitBulkDelete()" style="padding: 8px 20px;">Delete Selected</button>
        </div>
      </div>
      <div class="card" style="overflow-x: auto; padding: 0;">
        <table style="margin: 0;">
          <thead>
            <tr style="background: #1976d2; color: white;">
              <th style="width: 30px;"><input type="checkbox" id="selectAll" style="width: 18px; height: 18px; cursor: pointer;" onclick="toggleSelectAll(this)"></th>
              <th><a href="#{build_sort_url.call('id')}" style="color: white; text-decoration: none;">ID#{sort_arrow.call('id')}</a></th>
              <th><a href="#{build_sort_url.call('qty')}" style="color: white; text-decoration: none;">Qty#{sort_arrow.call('qty')}</a></th>
              <th><a href="#{build_sort_url.call('type')}" style="color: white; text-decoration: none;">Type#{sort_arrow.call('type')}</a></th>
              <th><a href="#{build_sort_url.call('design')}" style="color: white; text-decoration: none;">Design#{sort_arrow.call('design')}</a></th>
              <th><a href="#{build_sort_url.call('team')}" style="color: white; text-decoration: none;">Team#{sort_arrow.call('team')}</a></th>
              <th><a href="#{build_sort_url.call('customer')}" style="color: white; text-decoration: none;">Customer#{sort_arrow.call('customer')}</a></th>
              <th><a href="#{build_sort_url.call('number')}" style="color: white; text-decoration: none;">##{sort_arrow.call('number')}</a></th>
              <th><a href="#{build_sort_url.call('namebar')}" style="color: white; text-decoration: none;">Namebar#{sort_arrow.call('namebar')}</a></th>
              <th><a href="#{build_sort_url.call('age')}" style="color: white; text-decoration: none;">A/Y#{sort_arrow.call('age')}</a></th>
              <th><a href="#{build_sort_url.call('size')}" style="color: white; text-decoration: none;">Size#{sort_arrow.call('size')}</a></th>
              <th><a href="#{build_sort_url.call('color')}" style="color: white; text-decoration: none;">Color#{sort_arrow.call('color')}</a></th>
              <th><a href="#{build_sort_url.call('status')}" style="color: white; text-decoration: none;">Status#{sort_arrow.call('status')}</a></th>
              <th><a href="#{build_sort_url.call('payment')}" style="color: white; text-decoration: none;">Payment#{sort_arrow.call('payment')}</a></th>
              <th><a href="#{build_sort_url.call('ordered')}" style="color: white; text-decoration: none;">Ordered#{sort_arrow.call('ordered')}</a></th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            #{rows_html.empty? ? '<tr><td colspan="16" style="text-align: center; padding: 40px;">No jerseys found. <a href="/jerseys/new">Add your first jersey</a> or <button onclick="document.getElementById(\'uploadModal\').style.display=\'flex\'" style="background: none; border: none; color: #1976d2; cursor: pointer; text-decoration: underline;">upload a CSV</button></td></tr>' : rows_html}
          </tbody>
        </table>
      </div>
    </form>

    <script>
      function toggleSelectAll(checkbox) {
        var checkboxes = document.querySelectorAll('.jersey-checkbox');
        checkboxes.forEach(function(cb) {
          cb.checked = checkbox.checked;
        });
        updateBulkActions();
      }

      function updateBulkActions() {
        var checkboxes = document.querySelectorAll('.jersey-checkbox:checked');
        var count = checkboxes.length;
        document.getElementById('selectedCount').textContent = count;
        document.getElementById('bulkActions').style.display = count > 0 ? 'block' : 'none';
      }

      function clearSelection() {
        var checkboxes = document.querySelectorAll('.jersey-checkbox');
        checkboxes.forEach(function(cb) {
          cb.checked = false;
        });
        document.getElementById('selectAll').checked = false;
        updateBulkActions();
        // Also reset bulk update fields
        document.getElementById('bulk_status').value = '';
        document.getElementById('bulk_payment_status').value = '';
        document.getElementById('bulk_tracking_number').value = '';
        document.getElementById('bulk_date_delivered').value = '';
      }

      function submitBulkDelete() {
        var count = document.querySelectorAll('.jersey-checkbox:checked').length;
        if (confirm('Are you sure you want to delete ' + count + ' jersey(s)? This cannot be undone.')) {
          document.getElementById('bulk_action').value = 'delete';
          document.getElementById('bulkForm').action = '/jerseys/bulk-delete';
          document.getElementById('bulkForm').submit();
        }
      }

      function submitBulkUpdate() {
        var count = document.querySelectorAll('.jersey-checkbox:checked').length;
        var status = document.getElementById('bulk_status').value;
        var paymentStatus = document.getElementById('bulk_payment_status').value;
        var trackingNumber = document.getElementById('bulk_tracking_number').value;
        var dateDelivered = document.getElementById('bulk_date_delivered').value;

        if (!status && !paymentStatus && !trackingNumber && !dateDelivered) {
          alert('Please select at least one field to update.');
          return;
        }

        var changes = [];
        if (status) changes.push('Status: ' + status);
        if (paymentStatus) changes.push('Payment: ' + paymentStatus);
        if (trackingNumber) changes.push('Tracking: ' + trackingNumber);
        if (dateDelivered) changes.push('Date Delivered: ' + dateDelivered);

        if (confirm('Update ' + count + ' jersey(s) with:\\n' + changes.join('\\n'))) {
          document.getElementById('bulk_action').value = 'update';
          document.getElementById('bulkForm').action = '/jerseys/bulk-update';
          document.getElementById('bulkForm').submit();
        }
      }

      function handleBulkSubmit(event) {
        event.preventDefault();
        return false;
      }

      // Add event listeners to all checkboxes
      document.querySelectorAll('.jersey-checkbox').forEach(function(cb) {
        cb.addEventListener('change', updateBulkActions);
      });
    </script>

    <!-- Quick Actions -->
    <div class="card" style="display: flex; gap: 15px; flex-wrap: wrap; justify-content: center;">
      <a href="/scan" class="btn" style="padding: 15px 30px; font-size: 16px;"><span style="font-size: 20px;">&#128247;</span> Scan QR Code</a>
      <a href="/labels" class="btn" style="padding: 15px 30px; font-size: 16px; background: #9c27b0;"><span style="font-size: 20px;">&#128196;</span> Print All Labels</a>
    </div>

    <!-- Upload Modal -->
    <div id="uploadModal" style="display: none; position: fixed; top: 0; left: 0; right: 0; bottom: 0; background: rgba(0,0,0,0.5); z-index: 1000; justify-content: center; align-items: center;" onclick="if(event.target===this)this.style.display='none'">
      <div class="card" style="max-width: 500px; width: 90%; max-height: 80vh; overflow-y: auto;">
        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 15px;">
          <h2 style="margin: 0;">Upload CSV</h2>
          <button onclick="document.getElementById('uploadModal').style.display='none'" style="background: none; border: none; font-size: 24px; cursor: pointer;">&times;</button>
        </div>
        <form method="post" action="/upload" enctype="multipart/form-data">
          <div class="form-group">
            <label>Select CSV File</label>
            <input type="file" name="file" accept=".csv,.txt" required style="padding: 15px; border: 2px dashed #ccc; width: 100%; box-sizing: border-box;">
          </div>
          <button type="submit" class="btn btn-success" style="width: 100%; padding: 15px; font-size: 16px;">Upload & Import</button>
        </form>
        <div style="margin-top: 15px; padding: 15px; background: #f5f5f5; border-radius: 4px; font-size: 12px;">
          <strong>Expected columns:</strong><br>
          Customer Name, NUMBER, SIZE, NAMEBAR, COLOR, TYPE, DATE ORDERED, NOTES
        </div>
      </div>
    </div>
  HTML

  res.body = render_layout(content)
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
            <label>Design</label>
            <input type="text" name="design" placeholder="Design name/number">
          </div>
        </div>

        <div class="form-row">
          <div class="form-group">
            <label>Team</label>
            <input type="text" name="team" placeholder="Team name">
          </div>
          <div class="form-group">
            <label>Customer Name</label>
            <input type="text" name="customer_name" required>
          </div>
          <div class="form-group">
            <label>Number</label>
            <input type="text" name="number" placeholder="Jersey number">
          </div>
          <div class="form-group">
            <label>Namebar (exactly as shown)</label>
            <input type="text" name="namebar" placeholder="SMITH">
          </div>
        </div>

        <div class="form-row">
          <div class="form-group">
            <label>Age Group</label>
            <select name="age_group">
              <option value="Adult" selected>Adult</option>
              <option value="Youth">Youth</option>
            </select>
          </div>
          <div class="form-group">
            <label>Size</label>
            <select name="size" id="size-select">
              <option value="">Select Size</option>
              <option value="3XS">3XS</option>
              <option value="2XS">2XS</option>
              <option value="XS">XS</option>
              <option value="S">S</option>
              <option value="M">M</option>
              <option value="L">L</option>
              <option value="XL">XL</option>
              <option value="XXL">XXL</option>
              <option value="XXXL">XXXL</option>
            </select>
          </div>
          <div class="form-group">
            <label>Color</label>
            <input type="text" name="color" placeholder="e.g., Red, Blue">
          </div>
          <div class="form-group">
            <label>Type</label>
            <select name="type" id="type-select" onchange="updateSizeOptions()">
              <option value="">Select Type</option>
              <option value="Jersey">Jersey</option>
              <option value="Socks">Socks</option>
            </select>
          </div>
        </div>

        <div class="form-row">
          <div class="form-group">
            <label>Over Left Chest (4") Heart Side</label>
            <input type="text" name="chest_logo" placeholder="Logo/patch description">
          </div>
          <div class="form-group">
            <label>Status</label>
            <select name="status" id="status-select" onchange="toggleDeliveryFields()">
              <option value="ordered">Ordered</option>
              <option value="received">Received</option>
              <option value="inventory">In Inventory</option>
              <option value="delivered">Delivered</option>
            </select>
          </div>
          <div class="form-group">
            <label>Payment Status</label>
            <select name="payment_status">
              <option value="unpaid">Unpaid</option>
              <option value="invoiced">Invoiced</option>
              <option value="partial">Partial</option>
              <option value="paid">Paid</option>
            </select>
          </div>
          <div class="form-group">
            <label style="display: flex; align-items: center; gap: 8px; cursor: pointer;">
              <input type="checkbox" name="needs_remake" value="1" style="width: 18px; height: 18px;">
              Needs Remake
            </label>
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

        <div class="form-row" id="delivery-fields" style="display: none; background: #e3f2fd; padding: 15px; border-radius: 8px; margin-bottom: 15px;">
          <div class="form-group" style="flex: 2;">
            <label>Tracking Number</label>
            <input type="text" name="tracking_number" placeholder="Enter tracking number...">
          </div>
          <div class="form-group" style="flex: 1;">
            <label>Date Delivered</label>
            <input type="date" name="date_delivered">
          </div>
        </div>

        <div class="form-group">
          <label>Notes</label>
          <textarea name="notes" rows="3" placeholder="Any additional notes..."></textarea>
        </div>

        <button type="submit" class="btn btn-success">Create Item</button>
        <a href="/jerseys" class="btn">Cancel</a>
      </form>
      <script>
        const jerseySizes = ['', '3XS', '2XS', 'XS', 'S', 'M', 'L', 'XL', 'XXL', 'XXXL'];
        const sockSizes = ['', '18"', '20"', '22"', '24"', '26"', '28"', '30"', '32"'];

        function updateSizeOptions() {
          const typeSelect = document.getElementById('type-select');
          const sizeSelect = document.getElementById('size-select');
          const currentValue = sizeSelect.value;

          let sizes = jerseySizes;
          if (typeSelect.value === 'Socks') {
            sizes = sockSizes;
          }

          sizeSelect.innerHTML = '';
          sizes.forEach((size, i) => {
            const opt = document.createElement('option');
            opt.value = size;
            opt.text = size || 'Select Size';
            if (size === currentValue) opt.selected = true;
            sizeSelect.appendChild(opt);
          });
        }

        function toggleDeliveryFields() {
          const status = document.getElementById('status-select').value;
          const deliveryFields = document.getElementById('delivery-fields');
          if (status === 'received') {
            deliveryFields.style.display = 'flex';
          } else {
            deliveryFields.style.display = 'none';
          }
        }
      </script>
    </div>
  HTML

  res.body = LAYOUT % { content: content }
end

# Create jersey
server.mount_proc '/jerseys/create' do |req, res|
  if req.request_method == 'POST'
    begin
      body = req.body || ''
      params = URI.decode_www_form(body).to_h

      id = generate_jersey_id
      now = Time.now.strftime('%Y-%m-%d %H:%M:%S')

      # Normalize size and extract age group
      size_input = params['size']
      normalized_size, detected_age = normalize_size(size_input)
      age_group = params['age_group'] || detected_age
      needs_remake = params['needs_remake'] == '1' ? 1 : 0
      payment_status = params['payment_status'] || 'unpaid'

      DB.execute(
        "INSERT INTO jerseys (id, qty, type, color, design, customer_name, team, number, size, age_group, namebar, chest_logo, notes, date_ordered, date_invoiced, date_received, status, location, needs_remake, payment_status, tracking_number, date_delivered, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [id, params['qty'].to_i, params['type'], params['color'], params['design'], params['customer_name'], params['team'], params['number'], normalized_size, age_group, params['namebar'], params['chest_logo'], params['notes'], params['date_ordered'], params['date_invoiced'], params['date_received'], params['status'] || 'ordered', params['location'], needs_remake, payment_status, params['tracking_number'], params['date_delivered'], now, now]
      )

      # Log status creation
      DB.execute(
        "INSERT INTO status_history (jersey_id, old_status, new_status, location, changed_at, notes) VALUES (?, ?, ?, ?, ?, ?)",
        [id, nil, params['status'] || 'ordered', params['location'], now, 'Created']
      )

      res.set_redirect(WEBrick::HTTPStatus::SeeOther, "/jerseys/#{id}")
    rescue => e
      res['Content-Type'] = 'text/html'
      res.body = LAYOUT % { content: "<h1>Error</h1><p>#{h(e.message)}</p><a href='/jerseys/new' class='btn'>Back</a>" }
    end
  else
    res.set_redirect(WEBrick::HTTPStatus::SeeOther, "/jerseys/new")
  end
end

# View single jersey (and handle /jerseys list)
server.mount_proc '/jerseys/' do |req, res|
  # Extract ID from path
  path_parts = req.path.split('/')
  jersey_id = path_parts[2]
  action = path_parts[3]

  # Skip if this is handled by a more specific route
  if jersey_id == 'new' || jersey_id == 'create'
    next
  end

  # If no jersey_id, this is the list view - let /jerseys handle it
  if jersey_id.nil? || jersey_id.empty?
    # Redirect to list handler by calling the same logic
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
    next
  end

  # Handle different actions
  if action == 'edit'
    # Edit form - use find workaround due to parameterized query bug
    all_jerseys = DB.execute("SELECT * FROM jerseys")
    jersey = all_jerseys.find { |j| j['id'] == jersey_id }
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

    all_sizes = ['3XS', '2XS', 'XS', 'S', 'M', 'L', 'XL', 'XXL', 'XXXL', '18"', '20"', '22"', '24"', '26"', '28"', '30"', '32"']
    size_options = all_sizes.map do |s|
      selected = s == jersey['size'] ? ' selected' : ''
      "<option value=\"#{s}\"#{selected}>#{s}</option>"
    end.join

    age_group_options = ['Adult', 'Youth'].map do |ag|
      selected = ag == jersey['age_group'] ? ' selected' : ''
      "<option value=\"#{ag}\"#{selected}>#{ag}</option>"
    end.join

    status_options = STATUS_LABELS.map do |s, label|
      selected = s == jersey['status'] ? ' selected' : ''
      "<option value=\"#{s}\"#{selected}>#{label}</option>"
    end.join

    payment_status_options = PAYMENT_STATUS_LABELS.map do |s, label|
      selected = s == jersey['payment_status'] ? ' selected' : ''
      "<option value=\"#{s}\"#{selected}>#{label}</option>"
    end.join

    needs_remake_checked = jersey['needs_remake'].to_i == 1 ? ' checked' : ''

    # Calculate days since ordered
    days_since_ordered = nil
    days_to_received = nil
    if jersey['date_ordered'] && !jersey['date_ordered'].empty?
      begin
        order_date = Date.parse(jersey['date_ordered'])
        if jersey['date_received'] && !jersey['date_received'].empty?
          received_date = Date.parse(jersey['date_received'])
          days_to_received = (received_date - order_date).to_i
        else
          days_since_ordered = (Date.today - order_date).to_i
        end
      rescue
      end
    end

    # Build status buttons for easy status change (clickable buttons that update immediately)
    status_buttons = STATUS_LABELS.map do |s, label|
      color = STATUS_COLORS[s]
      is_current = jersey['status'] == s
      active_style = is_current ? "background: #{color}; color: white; box-shadow: 0 0 10px #{color};" : "background: transparent; border-color: #{color}; color: #{color};"
      "<button type=\"button\" class=\"status-btn\" data-status=\"#{s}\" style=\"#{active_style} padding: 10px 20px; border: 2px solid #{color}; border-radius: 6px; cursor: pointer; font-size: 14px; font-weight: bold; margin-right: 10px; margin-bottom: 10px; transition: all 0.2s;\">
        #{label}
      </button>"
    end.join

    # Build payment status buttons (clickable buttons that update immediately)
    payment_buttons = PAYMENT_STATUS_LABELS.map do |s, label|
      color = PAYMENT_STATUS_COLORS[s]
      is_current = jersey['payment_status'] == s
      active_style = is_current ? "background: #{color}; color: white; box-shadow: 0 0 8px #{color};" : "background: transparent; border-color: #{color}; color: #{color};"
      "<button type=\"button\" class=\"payment-btn\" data-payment=\"#{s}\" style=\"#{active_style} padding: 8px 16px; border: 2px solid #{color}; border-radius: 6px; cursor: pointer; font-size: 13px; font-weight: bold; margin-right: 8px; margin-bottom: 8px; transition: all 0.2s;\">
        #{label}
      </button>"
    end.join

    # Timeline display
    timeline_html = ""
    if jersey['date_ordered'] && !jersey['date_ordered'].empty?
      timeline_html = <<-TIMELINE
        <div class="card" style="background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%); margin-bottom: 20px;">
          <h3 style="margin-top: 0; color: #4fc3f7;">Order Timeline</h3>
          <div style="display: flex; align-items: center; gap: 15px; flex-wrap: wrap;">
            <div style="text-align: center; padding: 10px 15px; background: rgba(76, 175, 80, 0.2); border-radius: 8px; border: 1px solid #4caf50;">
              <div style="font-size: 12px; color: #81c784;">Ordered</div>
              <div style="font-size: 16px; font-weight: bold; color: #4caf50;">#{jersey['date_ordered']}</div>
            </div>
            <div style="flex: 1; height: 3px; background: linear-gradient(90deg, #4caf50, #{jersey['date_received'] && !jersey['date_received'].empty? ? '#2196f3' : '#ff9800'}); min-width: 50px; border-radius: 2px;"></div>
            #{if days_to_received
              "<div style=\"text-align: center; padding: 10px 15px; background: rgba(33, 150, 243, 0.2); border-radius: 8px; border: 1px solid #2196f3;\">
                <div style=\"font-size: 12px; color: #64b5f6;\">Received</div>
                <div style=\"font-size: 16px; font-weight: bold; color: #2196f3;\">#{jersey['date_received']}</div>
                <div style=\"font-size: 11px; color: #90caf9; margin-top: 4px;\">#{days_to_received} days</div>
              </div>"
            elsif days_since_ordered
              "<div style=\"text-align: center; padding: 10px 15px; background: rgba(255, 152, 0, 0.2); border-radius: 8px; border: 1px solid #ff9800; animation: pulse 2s infinite;\">
                <div style=\"font-size: 12px; color: #ffb74d;\">Waiting</div>
                <div style=\"font-size: 20px; font-weight: bold; color: #ff9800;\">#{days_since_ordered}</div>
                <div style=\"font-size: 11px; color: #ffcc80;\">days</div>
              </div>"
            else
              ""
            end}
          </div>
        </div>
        <style>
          @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.7; }
          }
        </style>
      TIMELINE
    end

    content = <<-HTML
      <h1>Edit Jersey #{h(jersey_id)}</h1>

      #{timeline_html}

      <div class="card">
        <form method="post" action="/jerseys/#{jersey_id}/update" id="editForm">
          <input type="hidden" name="status" id="status_input" value="#{jersey['status']}">
          <input type="hidden" name="payment_status" id="payment_input" value="#{jersey['payment_status']}">

          <h3 style="margin-top: 0; border-bottom: 1px solid #333; padding-bottom: 10px;">Status</h3>
          <div style="margin-bottom: 20px;">
            #{status_buttons}
          </div>

          <h3 style="border-bottom: 1px solid #333; padding-bottom: 10px;">Payment</h3>
          <div style="margin-bottom: 20px;">
            #{payment_buttons}
            <label style="display: inline-flex; align-items: center; gap: 8px; cursor: pointer; margin-left: 20px; padding: 6px 12px; background: #{jersey['needs_remake'].to_i == 1 ? 'rgba(244, 67, 54, 0.2)' : 'transparent'}; border: 2px solid #f44336; border-radius: 4px;">
              <input type="checkbox" name="needs_remake" value="1"#{needs_remake_checked} style="width: 16px; height: 16px;">
              <span style="color: #f44336;">Needs Remake</span>
            </label>
          </div>

          <h3 style="border-bottom: 1px solid #333; padding-bottom: 10px;">Jersey Details</h3>
          <div class="form-row">
            <div class="form-group">
              <label>Team</label>
              <input type="text" name="team" value="#{h(jersey['team'])}">
            </div>
            <div class="form-group">
              <label>Customer Name</label>
              <input type="text" name="customer_name" value="#{h(jersey['customer_name'])}" required>
            </div>
            <div class="form-group">
              <label>Namebar</label>
              <input type="text" name="namebar" value="#{h(jersey['namebar'])}">
            </div>
            <div class="form-group">
              <label>Number</label>
              <input type="text" name="number" value="#{h(jersey['number'])}">
            </div>
          </div>

          <div class="form-row">
            <div class="form-group">
              <label>Age Group</label>
              <select name="age_group">
                #{age_group_options}
              </select>
            </div>
            <div class="form-group">
              <label>Size</label>
              <select name="size" id="size-select">
                <option value="">Select Size</option>
                #{size_options}
              </select>
            </div>
            <div class="form-group">
              <label>Color</label>
              <input type="text" name="color" value="#{h(jersey['color'])}">
            </div>
            <div class="form-group">
              <label>Quantity</label>
              <input type="number" name="qty" value="#{jersey['qty']}" min="1">
            </div>
          </div>

          <div class="form-row">
            <div class="form-group">
              <label>Type</label>
              <select name="type" id="type-select" onchange="updateSizeOptions()">
                <option value="">Select Type</option>
                <option value="Jersey" #{jersey['type'] == 'Jersey' ? 'selected' : ''}>Jersey</option>
                <option value="Socks" #{jersey['type'] == 'Socks' ? 'selected' : ''}>Socks</option>
              </select>
            </div>
            <div class="form-group">
              <label>Design</label>
              <input type="text" name="design" value="#{h(jersey['design'])}">
            </div>
            <div class="form-group">
              <label>Chest Logo</label>
              <input type="text" name="chest_logo" value="#{h(jersey['chest_logo'])}">
            </div>
            <div class="form-group">
              <label>Location</label>
              <select name="location">
                <option value="">Select Location</option>
                #{location_options}
              </select>
            </div>
          </div>

          <h3 style="border-bottom: 1px solid #333; padding-bottom: 10px;">Dates</h3>
          <div class="form-row">
            <div class="form-group">
              <label>Date Ordered</label>
              <input type="date" name="date_ordered" value="#{date_to_html(jersey['date_ordered'])}">
            </div>
            <div class="form-group">
              <label>Date Invoiced</label>
              <input type="date" name="date_invoiced" value="#{date_to_html(jersey['date_invoiced'])}">
            </div>
            <div class="form-group">
              <label>Date Received</label>
              <input type="date" name="date_received" value="#{date_to_html(jersey['date_received'])}">
            </div>
          </div>

          <div class="form-row" id="delivery-fields" style="#{jersey['status'] == 'received' ? 'display: flex;' : 'display: none;'} background: #e3f2fd; padding: 15px; border-radius: 8px; margin-bottom: 15px;">
            <div class="form-group" style="flex: 2;">
              <label>Tracking Number</label>
              <input type="text" name="tracking_number" value="#{h(jersey['tracking_number'])}" placeholder="Enter tracking number...">
            </div>
            <div class="form-group" style="flex: 1;">
              <label>Date Delivered</label>
              <input type="date" name="date_delivered" value="#{date_to_html(jersey['date_delivered'])}">
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

      <script>
        // Size options for type switching
        const jerseySizes = ['', '3XS', '2XS', 'XS', 'S', 'M', 'L', 'XL', 'XXL', 'XXXL'];
        const sockSizes = ['', '18"', '20"', '22"', '24"', '26"', '28"', '30"', '32"'];

        function updateSizeOptions() {
          const typeSelect = document.getElementById('type-select');
          const sizeSelect = document.getElementById('size-select');
          if (!typeSelect || !sizeSelect) return;

          const currentValue = sizeSelect.value;
          let sizes = jerseySizes;
          if (typeSelect.value === 'Socks') {
            sizes = sockSizes;
          }

          sizeSelect.innerHTML = '';
          sizes.forEach((size, i) => {
            const opt = document.createElement('option');
            opt.value = size;
            opt.text = size || 'Select Size';
            if (size === currentValue) opt.selected = true;
            sizeSelect.appendChild(opt);
          });
        }

        // Status colors for visual update
        const statusColors = #{STATUS_COLORS.to_json};
        const paymentColors = #{PAYMENT_STATUS_COLORS.to_json};

        // Handle status button clicks
        document.querySelectorAll('.status-btn').forEach(btn => {
          btn.addEventListener('click', function() {
            const newStatus = this.dataset.status;

            // Update hidden input for form submission
            document.getElementById('status_input').value = newStatus;

            // Update button styles immediately
            document.querySelectorAll('.status-btn').forEach(b => {
              const color = statusColors[b.dataset.status];
              if (b.dataset.status === newStatus) {
                b.style.background = color;
                b.style.color = 'white';
                b.style.boxShadow = '0 0 10px ' + color;
              } else {
                b.style.background = 'transparent';
                b.style.color = color;
                b.style.boxShadow = 'none';
              }
            });

            // Submit status change via AJAX
            fetch('/jerseys/#{jersey_id}/status', {
              method: 'POST',
              headers: {'Content-Type': 'application/x-www-form-urlencoded'},
              body: 'status=' + encodeURIComponent(newStatus)
            }).then(response => {
              if (response.ok) {
                this.style.animation = 'pulse 0.3s';
                setTimeout(() => this.style.animation = '', 300);
              }
            });
          });
        });

        // Handle payment button clicks
        document.querySelectorAll('.payment-btn').forEach(btn => {
          btn.addEventListener('click', function() {
            const newPayment = this.dataset.payment;

            // Update hidden input for form submission
            document.getElementById('payment_input').value = newPayment;

            // Update button styles immediately
            document.querySelectorAll('.payment-btn').forEach(b => {
              const color = paymentColors[b.dataset.payment];
              if (b.dataset.payment === newPayment) {
                b.style.background = color;
                b.style.color = 'white';
                b.style.boxShadow = '0 0 8px ' + color;
              } else {
                b.style.background = 'transparent';
                b.style.color = color;
                b.style.boxShadow = 'none';
              }
            });

            // Submit payment change via AJAX
            fetch('/jerseys/#{jersey_id}/payment', {
              method: 'POST',
              headers: {'Content-Type': 'application/x-www-form-urlencoded'},
              body: 'payment_status=' + encodeURIComponent(newPayment)
            }).then(response => {
              if (response.ok) {
                this.style.animation = 'pulse 0.3s';
                setTimeout(() => this.style.animation = '', 300);
              }
            });
          });
        });
      </script>
    HTML

    res.body = LAYOUT % { content: content }

  elsif action == 'update' && req.request_method == 'POST'
    # Update jersey
    body = req.body || ''
    params = URI.decode_www_form(body).to_h

    old_jersey = DB.execute("SELECT status, location FROM jerseys WHERE id = ?", [jersey_id]).first
    now = Time.now.strftime('%Y-%m-%d %H:%M:%S')

    # Normalize size
    size_input = params['size']
    normalized_size, detected_age = normalize_size(size_input)
    age_group = params['age_group'] || detected_age

    # Handle checkbox and payment status
    needs_remake = params['needs_remake'] == '1' ? 1 : 0
    payment_status = params['payment_status'] || 'unpaid'

    # Use string interpolation for the WHERE clause to avoid parameterized query issues
    DB.execute(
      "UPDATE jerseys SET qty=?, type=?, color=?, design=?, customer_name=?, team=?, number=?, size=?, age_group=?, namebar=?, chest_logo=?, notes=?, date_ordered=?, date_invoiced=?, date_received=?, status=?, location=?, needs_remake=?, payment_status=?, tracking_number=?, date_delivered=?, updated_at=? WHERE id='#{jersey_id}'",
      [params['qty'].to_i, params['type'], params['color'], params['design'], params['customer_name'], params['team'], params['number'], normalized_size, age_group, params['namebar'], params['chest_logo'], params['notes'], params['date_ordered'], params['date_invoiced'], params['date_received'], params['status'], params['location'], needs_remake, payment_status, params['tracking_number'], params['date_delivered'], now]
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

    # Use find workaround for parameterized query
    all_jerseys = DB.execute("SELECT * FROM jerseys")
    old_jersey = all_jerseys.find { |j| j['id'] == jersey_id }

    unless old_jersey
      res.set_redirect(WEBrick::HTTPStatus::SeeOther, '/jerseys')
      next
    end

    now = Time.now.strftime('%Y-%m-%d %H:%M:%S')
    today = Time.now.strftime('%Y-%m-%d')

    new_status = params['status']
    is_ajax = params['location'].nil?
    new_location = is_ajax ? old_jersey['location'] : params['location']

    # If status is "received", auto-fill date_received if empty
    if new_status == 'received'
      current_date_received = old_jersey['date_received']
      if current_date_received.nil? || current_date_received.empty?
        if is_ajax
          # AJAX: only update status and date_received, not location
          DB.execute(
            "UPDATE jerseys SET status=?, date_received=?, updated_at=? WHERE id='#{jersey_id}'",
            [new_status, today, now]
          )
        else
          DB.execute(
            "UPDATE jerseys SET status=?, location=?, date_received=?, updated_at=? WHERE id='#{jersey_id}'",
            [new_status, new_location, today, now]
          )
        end
      else
        if is_ajax
          DB.execute(
            "UPDATE jerseys SET status=?, updated_at=? WHERE id='#{jersey_id}'",
            [new_status, now]
          )
        else
          DB.execute(
            "UPDATE jerseys SET status=?, location=?, updated_at=? WHERE id='#{jersey_id}'",
            [new_status, new_location, now]
          )
        end
      end
    else
      if is_ajax
        DB.execute(
          "UPDATE jerseys SET status=?, updated_at=? WHERE id='#{jersey_id}'",
          [new_status, now]
        )
      else
        DB.execute(
          "UPDATE jerseys SET status=?, location=?, updated_at=? WHERE id='#{jersey_id}'",
          [new_status, new_location, now]
        )
      end
    end

    DB.execute(
      "INSERT INTO status_history (jersey_id, old_status, new_status, location, changed_at, notes) VALUES (?, ?, ?, ?, ?, ?)",
      [jersey_id, old_jersey['status'], new_status, old_jersey['location'], now, params['notes']]
    )

    # Check if this is an AJAX request (no location param = from edit page buttons)
    if is_ajax
      res['Content-Type'] = 'text/plain'
      res.body = 'OK'
    else
      res.set_redirect(WEBrick::HTTPStatus::SeeOther, "/jerseys/#{jersey_id}")
    end

  elsif action == 'payment' && req.request_method == 'POST'
    # Quick payment status update (from edit page AJAX)
    body = req.body || ''
    params = URI.decode_www_form(body).to_h

    now = Time.now.strftime('%Y-%m-%d %H:%M:%S')
    new_payment = params['payment_status']

    DB.execute(
      "UPDATE jerseys SET payment_status=?, updated_at=? WHERE id='#{jersey_id}'",
      [new_payment, now]
    )

    res['Content-Type'] = 'text/plain'
    res.body = 'OK'

  elsif action == 'delete' && req.request_method == 'POST'
    DB.execute("DELETE FROM jerseys WHERE id='#{jersey_id}'")
    DB.execute("DELETE FROM status_history WHERE jersey_id='#{jersey_id}'")
    res.set_redirect(WEBrick::HTTPStatus::SeeOther, '/jerseys')

  elsif action == 'label'
    # Print label page - use find workaround
    all_jerseys = DB.execute("SELECT * FROM jerseys")
    jersey = all_jerseys.find { |j| j['id'] == jersey_id }
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
    # View jersey - workaround for parameterized query issue in WEBrick
    all_jerseys = DB.execute("SELECT * FROM jerseys")
    jersey = all_jerseys.find { |j| j['id'] == jersey_id }
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

    # Calculate days since ordered for view page
    view_days_since_ordered = nil
    view_days_to_received = nil
    if jersey['date_ordered'] && !jersey['date_ordered'].empty?
      begin
        order_date = Date.parse(jersey['date_ordered'])
        if jersey['date_received'] && !jersey['date_received'].empty?
          received_date = Date.parse(jersey['date_received'])
          view_days_to_received = (received_date - order_date).to_i
        else
          view_days_since_ordered = (Date.today - order_date).to_i
        end
      rescue
      end
    end

    # Timeline display for view page
    view_timeline_html = ""
    if jersey['date_ordered'] && !jersey['date_ordered'].empty?
      view_timeline_html = <<-TIMELINE
        <div class="card" style="background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%); margin-bottom: 20px;">
          <h3 style="margin-top: 0; color: #4fc3f7;">Order Timeline</h3>
          <div style="display: flex; align-items: center; gap: 15px; flex-wrap: wrap;">
            <div style="text-align: center; padding: 10px 15px; background: rgba(76, 175, 80, 0.2); border-radius: 8px; border: 1px solid #4caf50;">
              <div style="font-size: 12px; color: #81c784;">Ordered</div>
              <div style="font-size: 16px; font-weight: bold; color: #4caf50;">#{jersey['date_ordered']}</div>
            </div>
            <div style="flex: 1; height: 3px; background: linear-gradient(90deg, #4caf50, #{jersey['date_received'] && !jersey['date_received'].empty? ? '#2196f3' : '#ff9800'}); min-width: 50px; border-radius: 2px;"></div>
            #{if view_days_to_received
              "<div style=\"text-align: center; padding: 10px 15px; background: rgba(33, 150, 243, 0.2); border-radius: 8px; border: 1px solid #2196f3;\">
                <div style=\"font-size: 12px; color: #64b5f6;\">Received</div>
                <div style=\"font-size: 16px; font-weight: bold; color: #2196f3;\">#{jersey['date_received']}</div>
                <div style=\"font-size: 11px; color: #90caf9; margin-top: 4px;\">#{view_days_to_received} days</div>
              </div>"
            elsif view_days_since_ordered
              "<div style=\"text-align: center; padding: 10px 15px; background: rgba(255, 152, 0, 0.2); border-radius: 8px; border: 1px solid #ff9800; animation: pulse 2s infinite;\">
                <div style=\"font-size: 12px; color: #ffb74d;\">Waiting</div>
                <div style=\"font-size: 20px; font-weight: bold; color: #ff9800;\">#{view_days_since_ordered}</div>
                <div style=\"font-size: 11px; color: #ffcc80;\">days</div>
              </div>"
            else
              ""
            end}
          </div>
        </div>
        <style>
          @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.7; }
          }
        </style>
      TIMELINE
    end

    content = <<-HTML
      <h1>Jersey #{h(jersey_id)}</h1>

      #{view_timeline_html}

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
            <tr><th width="150">Team</th><td><strong>#{h(jersey['team']) || '-'}</strong></td></tr>
            <tr><th>Customer</th><td><strong>#{h(jersey['customer_name'])}</strong></td></tr>
            <tr><th>Namebar</th><td><strong style="font-size: 18px;">#{h(jersey['namebar'])}</strong></td></tr>
            <tr><th>Number</th><td><strong style="font-size: 18px;">##{h(jersey['number'])}</strong></td></tr>
            <tr><th>Age Group</th><td>#{h(jersey['age_group']) || 'Adult'}</td></tr>
            <tr><th>Size</th><td>#{h(jersey['size'])}</td></tr>
            <tr><th>Type</th><td>#{h(jersey['type'])}</td></tr>
            <tr><th>Color</th><td>#{h(jersey['color'])}</td></tr>
            <tr><th>Design</th><td>#{h(jersey['design'])}</td></tr>
            <tr><th>Chest Logo</th><td>#{h(jersey['chest_logo'])}</td></tr>
            <tr><th>Quantity</th><td>#{jersey['qty']}</td></tr>
            <tr><th>Location</th><td>#{h(jersey['location']) || '-'}</td></tr>
            <tr><th>Payment Status</th><td><span class="status-badge" style="background: #{PAYMENT_STATUS_COLORS[jersey['payment_status']] || '#666'};">#{PAYMENT_STATUS_LABELS[jersey['payment_status']] || 'Unpaid'}</span></td></tr>
            <tr><th>Needs Remake</th><td>#{jersey['needs_remake'].to_i == 1 ? '<span style="color: #f44336; font-weight: bold;">Yes</span>' : 'No'}</td></tr>
            <tr><th>Date Ordered</th><td>#{jersey['date_ordered'] || '-'}</td></tr>
            <tr><th>Date Invoiced</th><td>#{jersey['date_invoiced'] || '-'}</td></tr>
            <tr><th>Date Received</th><td>#{jersey['date_received'] || '-'}</td></tr>
            #{jersey['tracking_number'] && !jersey['tracking_number'].empty? ? "<tr><th>Tracking Number</th><td>#{h(jersey['tracking_number'])}</td></tr>" : ''}
            #{jersey['date_delivered'] && !jersey['date_delivered'].empty? ? "<tr><th>Date Delivered</th><td>#{jersey['date_delivered']}</td></tr>" : ''}
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

# Locations management page
server.mount_proc '/locations' do |req, res|
  res['Content-Type'] = 'text/html'

  # Handle POST actions (add/delete)
  if req.request_method == 'POST'
    body = req.body || ''
    params = URI.decode_www_form(body).to_h
    action = params['action']

    if action == 'add' && params['name'] && !params['name'].empty?
      begin
        DB.execute("INSERT INTO locations (name, description) VALUES (?, ?)",
          [params['name'].strip, params['description']&.strip])
      rescue SQLite3::ConstraintException
        # Location already exists, ignore
      end
    elsif action == 'delete' && params['id']
      loc_id = params['id'].to_i
      # Check if location is in use
      count = DB.get_first_value("SELECT COUNT(*) FROM jerseys WHERE location = (SELECT name FROM locations WHERE id = ?)", [loc_id])
      if count == 0
        DB.execute("DELETE FROM locations WHERE id = ?", [loc_id])
      end
    end

    res.set_redirect(WEBrick::HTTPStatus::SeeOther, '/locations')
    next
  end

  # Get all locations with usage counts
  locations = DB.execute("SELECT l.id, l.name, l.description,
    (SELECT COUNT(*) FROM jerseys WHERE location = l.name) as jersey_count
    FROM locations l ORDER BY l.name")

  location_rows = locations.map do |loc|
    can_delete = loc['jersey_count'] == 0
    delete_btn = if can_delete
      "<form method=\"post\" style=\"display: inline;\" onsubmit=\"return confirm('Delete location #{h(loc['name'])}?');\">
        <input type=\"hidden\" name=\"action\" value=\"delete\">
        <input type=\"hidden\" name=\"id\" value=\"#{loc['id']}\">
        <button type=\"submit\" class=\"btn\" style=\"background: #dc3545; padding: 4px 10px; font-size: 12px;\">Delete</button>
      </form>"
    else
      "<span style=\"color: #666; font-size: 12px;\">(in use)</span>"
    end

    "<tr>
      <td>#{h(loc['name'])}</td>
      <td>#{h(loc['description'])}</td>
      <td style=\"text-align: center;\">#{loc['jersey_count']}</td>
      <td style=\"text-align: center;\">#{delete_btn}</td>
    </tr>"
  end.join

  content = <<-HTML
    <h1>Manage Locations</h1>

    <div class="card" style="margin-bottom: 20px;">
      <h3 style="margin-top: 0;">Add New Location</h3>
      <form method="post" style="display: flex; gap: 10px; align-items: flex-end; flex-wrap: wrap;">
        <input type="hidden" name="action" value="add">
        <div style="flex: 1; min-width: 150px;">
          <label style="display: block; margin-bottom: 4px; font-size: 12px; color: #888;">Name *</label>
          <input type="text" name="name" placeholder="Location name" required style="width: 100%;">
        </div>
        <div style="flex: 2; min-width: 200px;">
          <label style="display: block; margin-bottom: 4px; font-size: 12px; color: #888;">Description</label>
          <input type="text" name="description" placeholder="Optional description" style="width: 100%;">
        </div>
        <button type="submit" class="btn btn-success" style="padding: 10px 20px;">Add Location</button>
      </form>
    </div>

    <div class="card">
      <h3 style="margin-top: 0;">Current Locations</h3>
      <table class="data-table">
        <thead>
          <tr>
            <th>Name</th>
            <th>Description</th>
            <th style="text-align: center;">Jerseys</th>
            <th style="text-align: center;">Action</th>
          </tr>
        </thead>
        <tbody>
          #{location_rows}
        </tbody>
      </table>
      <p style="color: #888; font-size: 12px; margin-top: 15px;">
        Note: Only locations with 0 jerseys can be deleted.
      </p>
    </div>

    <div style="margin-top: 20px;">
      <a href="/jerseys" class="btn">Back to Jerseys</a>
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

# Upload CSV/Excel page
server.mount_proc '/upload' do |req, res|
  res['Content-Type'] = 'text/html'

  if req.request_method == 'POST'
    # Handle file upload
    begin
      # Parse multipart form data
      body = req.body || ''
      boundary = req.content_type.to_s.match(/boundary=(.+)/i)&.[](1)

      unless boundary
        raise "No file uploaded"
      end

      # Extract file content from multipart data
      parts = body.split("--#{boundary}")
      file_content = nil

      parts.each do |part|
        if part.include?('name="file"') && part.include?('filename=')
          # Find the content after the headers (double newline)
          content_start = part.index("\r\n\r\n") || part.index("\n\n")
          if content_start
            file_content = part[(content_start + 4)..-1]
            # Remove trailing boundary markers
            file_content = file_content.sub(/\r?\n?--\r?\n?$/, '').sub(/\r?\n$/, '')
          end
        end
      end

      raise "No file content found" unless file_content && !file_content.empty?

      # Parse CSV
      imported = 0
      errors = []

      CSV.parse(file_content, headers: true, liberal_parsing: true) do |row|
        begin
          id = generate_jersey_id
          now = Time.now.strftime('%Y-%m-%d %H:%M:%S')

          # Map CSV columns to database fields (flexible column naming)
          qty = (row['QTY'] || row['Qty'] || row['qty'] || row['Quantity'] || '1').to_i
          qty = 1 if qty < 1

          type = row['TYPE'] || row['Type'] || row['type'] || ''
          color = row['COLOR'] || row['Color'] || row['color'] || ''
          design = row['DESIGN'] || row['Design'] || row['design'] || ''
          team = row['TEAM'] || row['Team'] || row['team'] || ''
          customer_name = row['Customer Name'] || row['CUSTOMER NAME'] || row['customer_name'] || row['Customer'] || row['Name'] || ''
          number = row['NUMBER'] || row['Number'] || row['number'] || row['#'] || row['Jersey Number'] || row['_wccf_pf_jersey_number'] || ''
          size_raw = row['SIZE'] || row['Size'] || row['size'] || row['Jersey Size'] || row['_wccf_pf_jersey_size'] || ''
          namebar = row['NAMEBAR ( exactly as shown)'] || row['NAMEBAR '] || row['NAMEBAR'] || row['Namebar'] || row['namebar'] || row['Name Bar'] || row['Jersey Namebar'] || row['_wccf_pf_jersey_name'] || ''
          chest_logo = row['Over left chest(4") heart side'] || row['Chest Logo'] || row['chest_logo'] || row['CHEST LOGO'] || ''
          notes = row['NOTES'] || row['Notes'] || row['notes'] || ''
          date_ordered = row['DATE ORDERED'] || row['Date Ordered'] || row['date_ordered'] || ''
          date_invoiced = row['Date Invoiced'] || row['DATE INVOICED'] || row['date_invoiced'] || ''
          date_received = row['Date Received'] || row['DATE RECEIVED'] || row['date_received'] || ''

          # Normalize size and extract age group
          size, age_group = normalize_size(size_raw)

          # Convert MM/DD/YYYY to YYYY-MM-DD for HTML date inputs
          [date_ordered, date_invoiced, date_received].each_with_index do |d, i|
            if d =~ %r{^(\d{1,2})/(\d{1,2})/(\d{4})$}
              converted = "#{$3}-#{$1.rjust(2,'0')}-#{$2.rjust(2,'0')}"
              case i
              when 0 then date_ordered = converted
              when 1 then date_invoiced = converted
              when 2 then date_received = converted
              end
            end
          end
          status = row['Status'] || row['STATUS'] || row['status'] || 'ordered'
          location = row['Location'] || row['LOCATION'] || row['location'] || ''

          # Normalize status
          status = status.to_s.downcase.strip
          status = 'ordered' unless STATUS_LABELS.keys.include?(status)

          DB.execute(
            "INSERT INTO jerseys (id, qty, type, color, design, customer_name, team, number, size, age_group, namebar, chest_logo, notes, date_ordered, date_invoiced, date_received, status, location, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [id, qty, type, color, design, customer_name, team, number, size, age_group, namebar, chest_logo, notes, date_ordered, date_invoiced, date_received, status, location, now, now]
          )

          # Log status creation
          DB.execute(
            "INSERT INTO status_history (jersey_id, old_status, new_status, location, changed_at, notes) VALUES (?, ?, ?, ?, ?, ?)",
            [id, nil, status, location, now, 'Imported from CSV']
          )

          imported += 1
        rescue => e
          errors << "Row #{imported + errors.length + 2}: #{e.message}"
        end
      end

      result_html = "<div class='card' style='background: #e8f5e9; border: 2px solid #4caf50;'>
        <h2 style='color: #2e7d32;'>Import Complete</h2>
        <p><strong>#{imported}</strong> jerseys imported successfully.</p>
        #{errors.empty? ? '' : "<p style='color: #c62828;'><strong>Errors:</strong><br>#{errors.first(10).map { |e| h(e) }.join('<br>')}</p>"}
        <a href='/jerseys' class='btn btn-success'>View Jerseys</a>
        <a href='/upload' class='btn'>Upload More</a>
      </div>"

      content = <<-HTML
        <h1>Upload Complete</h1>
        #{result_html}
      HTML

    rescue => e
      content = <<-HTML
        <h1>Upload Error</h1>
        <div class="card" style="background: #ffebee; border: 2px solid #f44336;">
          <p style="color: #c62828;"><strong>Error:</strong> #{h(e.message)}</p>
          <a href="/upload" class="btn">Try Again</a>
        </div>
      HTML
    end

    res.body = LAYOUT % { content: content }
  else
    # Show upload form
    content = <<-HTML
      <h1>Upload Jerseys from CSV/Excel</h1>

      <div class="card">
        <form method="post" enctype="multipart/form-data">
          <div class="form-group">
            <label>Select CSV File</label>
            <input type="file" name="file" accept=".csv,.txt" required style="padding: 10px;">
          </div>
          <button type="submit" class="btn btn-success">Upload & Import</button>
        </form>
      </div>

      <div class="card">
        <h2>CSV Format</h2>
        <p>Your CSV file should have headers in the first row. Supported columns:</p>
        <table>
          <thead>
            <tr>
              <th>Column</th>
              <th>Description</th>
              <th>Example</th>
            </tr>
          </thead>
          <tbody>
            <tr><td>QTY</td><td>Quantity (default: 1)</td><td>1</td></tr>
            <tr><td>TYPE</td><td>Jersey type</td><td>Home</td></tr>
            <tr><td>COLOR</td><td>Color</td><td>Red</td></tr>
            <tr><td>DESIGN</td><td>Design name</td><td>Classic</td></tr>
            <tr><td>Customer Name</td><td>Customer name</td><td>John Smith</td></tr>
            <tr><td>NUMBER</td><td>Jersey number</td><td>42</td></tr>
            <tr><td>SIZE</td><td>Size (YS,YM,YL,AS,AM,AL,AXL,etc)</td><td>AL</td></tr>
            <tr><td>NAMEBAR</td><td>Name on back (exactly as shown)</td><td>SMITH</td></tr>
            <tr><td>Chest Logo</td><td>Left chest logo description</td><td>Team A</td></tr>
            <tr><td>NOTES</td><td>Additional notes</td><td>Rush order</td></tr>
            <tr><td>DATE ORDERED</td><td>Date ordered (YYYY-MM-DD)</td><td>2025-01-01</td></tr>
            <tr><td>Date Invoiced</td><td>Date invoiced</td><td>2025-01-02</td></tr>
            <tr><td>Date Received</td><td>Date received</td><td>2025-01-15</td></tr>
            <tr><td>Status</td><td>ordered/received/inventory/delivered/need_remake</td><td>ordered</td></tr>
            <tr><td>Location</td><td>Storage location</td><td>Warehouse</td></tr>
          </tbody>
        </table>

        <h3 style="margin-top: 20px;">Sample CSV</h3>
        <pre style="background: #f5f5f5; padding: 15px; overflow-x: auto; font-size: 12px;">Customer Name,NUMBER,SIZE,NAMEBAR,COLOR,TYPE,NOTES
John Smith,42,AL,SMITH,Red,Home,
Jane Doe,17,AM,DOE,Blue,Away,Rush order</pre>

        <p style="margin-top: 15px; color: #666;">
          <strong>Tip:</strong> You can export from Excel as CSV (Save As > CSV UTF-8)
        </p>
      </div>
    HTML

    res.body = LAYOUT % { content: content }
  end
end

# Bulk delete endpoint
server.mount_proc '/jerseys/bulk-delete' do |req, res|
  if req.request_method == 'POST'
    begin
      body = req.body || ''
      params = body.empty? ? [] : URI.decode_www_form(body)

      # Extract all ids[] values
      ids = params.select { |k, v| k == 'ids[]' }.map { |k, v| v }

      if ids.empty?
        res.set_redirect(WEBrick::HTTPStatus::SeeOther, '/')
        next
      end

      deleted = 0
      ids.each do |id|
        DB.execute("DELETE FROM jerseys WHERE id = ?", [id])
        DB.execute("DELETE FROM status_history WHERE jersey_id = ?", [id])
        deleted += 1
      end

      res.set_redirect(WEBrick::HTTPStatus::SeeOther, "/?deleted=#{deleted}")
    rescue WEBrick::HTTPStatus::Status
      raise
    rescue => e
      res['Content-Type'] = 'text/html'
      res.body = LAYOUT % { content: "<h1>Error</h1><p>#{h(e.message)}</p><a href='/' class='btn'>Back</a>" }
    end
  else
    res.set_redirect(WEBrick::HTTPStatus::SeeOther, '/')
  end
end

# Bulk update endpoint
server.mount_proc '/jerseys/bulk-update' do |req, res|
  if req.request_method == 'POST'
    begin
      body = req.body || ''
      params_array = body.empty? ? [] : URI.decode_www_form(body)

      # Extract all ids[] values
      ids = params_array.select { |k, v| k == 'ids[]' }.map { |k, v| v }

      if ids.empty?
        res.set_redirect(WEBrick::HTTPStatus::SeeOther, '/')
        next
      end

      # Get the values to update
      params = params_array.to_h
      bulk_status = params['bulk_status']
      bulk_payment_status = params['bulk_payment_status']
      bulk_tracking_number = params['bulk_tracking_number']
      bulk_date_delivered = params['bulk_date_delivered']

      # Build dynamic UPDATE query
      set_clauses = []
      update_values = []

      if bulk_status && !bulk_status.empty?
        set_clauses << "status = ?"
        update_values << bulk_status
      end

      if bulk_payment_status && !bulk_payment_status.empty?
        set_clauses << "payment_status = ?"
        update_values << bulk_payment_status
      end

      if bulk_tracking_number && !bulk_tracking_number.empty?
        set_clauses << "tracking_number = ?"
        update_values << bulk_tracking_number
      end

      if bulk_date_delivered && !bulk_date_delivered.empty?
        set_clauses << "date_delivered = ?"
        update_values << bulk_date_delivered
      end

      if set_clauses.empty?
        res.set_redirect(WEBrick::HTTPStatus::SeeOther, '/')
        next
      end

      # Add updated_at
      set_clauses << "updated_at = ?"
      update_values << Time.now.strftime('%Y-%m-%d %H:%M:%S')

      updated = 0
      ids.each do |id|
        DB.execute("UPDATE jerseys SET #{set_clauses.join(', ')} WHERE id = ?", update_values + [id])
        updated += 1
      end

      res.set_redirect(WEBrick::HTTPStatus::SeeOther, "/?updated=#{updated}")
    rescue WEBrick::HTTPStatus::Status
      raise
    rescue => e
      res['Content-Type'] = 'text/html'
      res.body = LAYOUT % { content: "<h1>Error</h1><p>#{h(e.message)}</p><a href='/' class='btn'>Back</a>" }
    end
  else
    res.set_redirect(WEBrick::HTTPStatus::SeeOther, '/')
  end
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
