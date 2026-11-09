from flask import Flask, request, jsonify
import face_recognition
import os
import json
import mysql.connector
from datetime import datetime
from flask_cors import CORS
from dotenv import load_dotenv

# Load environment variables from .env (same folder as this file)
load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), '.env'))

DB_HOST = os.getenv('DB_HOST', 'localhost')
DB_PORT = int(os.getenv('DB_PORT', '3306'))
DB_USER = os.getenv('DB_USER', 'root')
DB_PASSWORD = os.getenv('DB_PASSWORD', '')
DB_NAME = os.getenv('DB_NAME', 'faceentry')

FLASK_HOST = os.getenv('FLASK_HOST', '0.0.0.0')
FLASK_PORT = int(os.getenv('FLASK_PORT', '8000'))
FLASK_DEBUG = os.getenv('FLASK_DEBUG', 'False').lower() in ('1', 'true', 'yes')

FACE_TOLERANCE = float(os.getenv('FACE_TOLERANCE', '0.6'))

app = Flask(__name__)
CORS(app)  # Enable CORS for all routes

# MySQL Database Connection
db = mysql.connector.connect(
    host=DB_HOST,
    port=DB_PORT,
    user=DB_USER,
    password=DB_PASSWORD,
    database=DB_NAME
)
cursor = db.cursor()

@app.route('/api/register', methods=['POST'])
def register_employee():
    """
    Register a new employee with face encoding
    Expects: { name, employee_id, image file }
    """
    try:
        name = request.form.get('name')
        employee_id = request.form.get('employee_id')
        image_file = request.files.get('image')
        
        if not name or not employee_id or not image_file:
            return jsonify({'error': 'Missing required fields'}), 400
            
        image_path = f'temp_reg_{employee_id}.jpg'
        image_file.save(image_path)
        
        # Get face encoding
        image = face_recognition.load_image_file(image_path)
        face_locations = face_recognition.face_locations(image)
        
        if not face_locations:
            os.remove(image_path)
            return jsonify({'error': 'No face found in the image'}), 400
            
        face_encoding = face_recognition.face_encodings(image, face_locations)[0]
        encoding_json = json.dumps(face_encoding.tolist())
        
        # Store in database
        try:
            # Check if employee already exists
            cursor.execute("SELECT * FROM employees WHERE employee_id = %s", (employee_id,))
            if cursor.fetchone():
                # Update existing employee
                update_query = """
                UPDATE employees 
                SET name = %s, encoding = %s
                WHERE employee_id = %s
                """
                cursor.execute(update_query, (name, encoding_json, employee_id))
            else:
                # Insert new employee
                insert_query = """
                INSERT INTO employees (employee_id, name, encoding)
                VALUES (%s, %s, %s)
                """
                cursor.execute(insert_query, (employee_id, name, encoding_json))
                
            db.commit()
            os.remove(image_path)
            return jsonify({'message': 'Employee registered successfully'}), 200
            
        except mysql.connector.Error as err:
            db.rollback()
            return jsonify({'error': f'Database error: {err}'}), 500
            
    except Exception as e:
        return jsonify({'error': f'Registration failed: {str(e)}'}), 500

@app.route('/api/recognize', methods=['POST'])
def recognize():
    image_file = request.files.get('image')

    if not image_file:
        return jsonify({'error': 'No image provided'}), 400

    image_path = 'temp.jpg'
    image_file.save(image_path)
    
    # Load image and detect faces
    unknown_image = face_recognition.load_image_file(image_path)
    face_locations = face_recognition.face_locations(unknown_image)
    unknown_encodings = face_recognition.face_encodings(unknown_image, face_locations)

    if not unknown_encodings:
        os.remove(image_path)
        return jsonify({'error': 'No face found'}), 400

    unknown_encoding = unknown_encodings[0]
    face_location = face_locations[0]  # Get the first face location

    # Check against known faces in database
    cursor.execute("SELECT employee_id, name, encoding FROM employees WHERE encoding IS NOT NULL")
    
    for emp_id, name, encoding_json in cursor.fetchall():
        known_encoding = json.loads(encoding_json)
        
        # Compare faces with a looser tolerance for better matching
        # Standard is 0.6, but we can make it a bit more lenient
        face_distance = face_recognition.face_distance([known_encoding], unknown_encoding)
        
        if face_distance[0] <= 0.6:  # Adjust tolerance as needed
            # Record attendance in the database
            try:
                insert_query = """
                INSERT INTO attendance_logs (employee_id, timestamp)
                VALUES (%s, %s)
                """
                current_time = datetime.now()
                cursor.execute(insert_query, (emp_id, current_time))
                db.commit()
                
                os.remove(image_path)
                return jsonify({
                    'message': f'Matched: {name}',
                    'name': name,
                    'employee_id': emp_id,
                    'timestamp': current_time.strftime('%Y-%m-%d %H:%M:%S'),
                    'face_location': face_location  # Return face location for rectangle drawing
                }), 200
            except mysql.connector.Error as err:
                db.rollback()
                return jsonify({'error': f'Database error: {err}'}), 500

    os.remove(image_path)
    return jsonify({'message': 'No match found'}), 404

# @app.route('/api/attendance', methods=['GET'])
# def get_attendance():
#     """Get attendance logs with employee names"""
#     try:
#         query = """
#         SELECT a.id, a.employee_id, e.name, a.timestamp
#         FROM attendance_logs a
#         JOIN employees e ON a.employee_id = e.employee_id
#         ORDER BY a.timestamp DESC
#         LIMIT 100
#         """
#         cursor.execute(query)
        
#         columns = [col[0] for col in cursor.description]
#         attendance_data = [dict(zip(columns, row)) for row in cursor.fetchall()]
        
#         return jsonify({
#             'attendance': attendance_data
#         }), 200
        
#     except mysql.connector.Error as err:
#         return jsonify({'error': f'Database error: {err}'}), 500

if __name__ == '__main__':
    app.run(host=FLASK_HOST, port=FLASK_PORT, debug=FLASK_DEBUG)