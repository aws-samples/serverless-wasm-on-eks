use anyhow::{Result};
use spin_sdk::{
    http::{IntoResponse, Request, Response, ResponseBuilder, Method},
    http_component, redis, variables
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;
use serde_json::json;

#[derive(Deserialize, Serialize, Debug)]
struct CartItem {
    name: String,
    price: f64,
    quantity: i32,
}

fn cors_preflight() -> Response {
    ResponseBuilder::new(204)
        .header("Access-Control-Allow-Origin", "*")
        .header("Access-Control-Allow-Methods", "POST, OPTIONS")
        .header("Access-Control-Allow-Headers", "Content-Type")
        .build()
}

fn cors_response(status: u16, body: Option<String>) -> Response {
    let mut builder = ResponseBuilder::new(status);
    builder.header("Access-Control-Allow-Origin", "*");
    builder.header("Content-Type", "application/json");
    if let Some(b) = body {
        builder.body(b);
    }
    builder.build()
}

#[http_component]
fn handle_add_to_cart(req: Request) -> Result<impl IntoResponse> {
    println!("Received add-to-cart request");

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
    println!("Request body received: {:?}", body);

    let cart_item: CartItem = match serde_json::from_slice(body) {
        Ok(item) => {
            println!("Successfully parsed cart item: {:?}", item);
            item
        },
        Err(e) => {
            println!("Failed to parse JSON: {}", e);
            return Ok(cors_response(400, Some("Invalid JSON".to_string())));
        }
    };

    println!("Retrieving Valkey configuration");
    let valkey_host = variables::get("valkey_host")?;
    let valkey_password = variables::get("valkey_password")?;

    let valkey_url = format!("redis://:{}@{}/0", valkey_password, valkey_host);

    println!("Connecting to Valkey");
    let conn = redis::Connection::open(&valkey_url)?;

    let cart_id = Uuid::new_v4().to_string();
    println!("Generated cart ID: {}", cart_id);
    
    conn.set(&format!("{}:name", cart_id), &cart_item.name.into_bytes())?;
    conn.set(&format!("{}:price", cart_id), &cart_item.price.to_string().into_bytes())?;
    conn.set(&format!("{}:quantity", cart_id), &cart_item.quantity.to_string().into_bytes())?;

    println!("Successfully added item to cart");
    let response_body = json!({
        "message": "Item added to cart",
        "cartId": cart_id
    }).to_string();
    Ok(cors_response(200, Some(response_body)))
}
