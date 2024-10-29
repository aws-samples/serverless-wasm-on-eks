use anyhow::{Result};
use spin_sdk::{
    http::{IntoResponse, Request, Response, ResponseBuilder, Method},
    http_component, redis, variables
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use spin_sdk::redis::{RedisParameter};

#[derive(Deserialize, Serialize, Debug)]
struct DeleteRequest {
    cart_id: String,
}

fn cors_preflight() -> Response {
    ResponseBuilder::new(204)
        .header("Access-Control-Allow-Origin", "*")
        .header("Access-Control-Allow-Methods", "POST, OPTIONS")
        .header("Access-Control-Allow-Headers", "Content-Type")
        .header("Access-Control-Allow-Credentials", "true")
        .header("Access-Control-Max-Age", "86400")
        .build()
}

fn cors_response(status: u16, body: Option<String>) -> Response {
    let mut builder = ResponseBuilder::new(status);
    builder.header("Access-Control-Allow-Origin", "*");
    builder.header("Access-Control-Allow-Credentials", "true");
    builder.header("Content-Type", "application/json");
    if let Some(b) = body {
        builder.body(b);
    }
    builder.build()
}

#[http_component]
fn handle_delete_from_cart(req: Request) -> Result<impl IntoResponse> {
    println!("Function called");

    if *req.method() == Method::Options {
        println!("Handling OPTIONS request");
        return Ok(cors_preflight());
    }

    if *req.method() != Method::Post {
        println!("Method not allowed: {}", req.method());
        return Ok(cors_response(405, Some("Method Not Allowed".to_string())));
    }

    println!("Processing POST request");

    let body = req.body();
    println!("Request body received: {:?}", String::from_utf8_lossy(body));

    let delete_request: DeleteRequest = match serde_json::from_slice(body) {
        Ok(req) => {
            println!("Successfully parsed delete request: {:?}", req);
            req
        },
        Err(e) => {
            println!("Failed to parse JSON: {}. Body: {:?}", e, String::from_utf8_lossy(body));
            return Ok(cors_response(400, Some(format!("Invalid JSON: {}", e))));
        }
    };

    println!("Retrieving Valkey configuration");
    let valkey_host = variables::get("valkey_host")?;
    let valkey_password = variables::get("valkey_password")?;

    let valkey_url = format!("redis://:{}@{}/0", valkey_password, valkey_host);

    println!("Connecting to Valkey");
    let conn = redis::Connection::open(&valkey_url)?;

    // Delete the item from Valkey
    let keys_to_delete = vec![
        format!("{}:name", delete_request.cart_id),
        format!("{}:price", delete_request.cart_id),
        format!("{}:quantity", delete_request.cart_id),
    ];

    for key in keys_to_delete {
        match conn.execute("DEL", &[RedisParameter::Binary(key.clone().into_bytes())]) {
            Ok(_) => println!("Successfully deleted key: {}", key),
            Err(e) => println!("Error deleting key {}: {:?}", key, e),
        }
    }

    println!("Successfully deleted item from cart");
    let response_body = json!({
        "message": "Item deleted from cart",
        "cartId": delete_request.cart_id
    }).to_string();
    Ok(cors_response(200, Some(response_body)))
}
