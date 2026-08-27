from flask import Flask, jsonify

app = Flask(__name__, static_folder="/srv/static", static_url_path="/static")


@app.route("/")
def index():
    return app.send_static_file("index.html")


@app.route("/api/hello")
def hello():
    return jsonify({"message": "Hello from Middle-earth!", "service": "example"})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
