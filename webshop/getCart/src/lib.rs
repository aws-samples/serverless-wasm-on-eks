use anyhow::{anyhow, Result};
use spin_sdk::{
    http::{IntoResponse, Request, Response, ResponseBuilder, Method},
    http_component, redis, variables
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use spin_sdk::redis::{RedisParameter, RedisResult};
use std::collections::{HashMap};

#[derive(Deserialize, Serialize, Debug)]
struct CartItem {
    id: String,
    name: String,
    price: f64,
    quantity: i32,
}

fn cors_preflight() -> Response {
    ResponseBuilder::new(204)
        .header("Access-Control-Allow-Origin", "*")
        .header("Access-Control-Allow-Methods", "GET, OPTIONS")
        .header("Access-Control-Allow-Headers", "Content-Type")
        .header("Access-Control-Max-Age", "86400")
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
fn handle_get_cart(req: Request) -> Result<impl IntoResponse> {
    println!("Function called with method: {:?}", req.method());

    // Handle CORS preflight request
    if *req.method() == Method::Options {
        println!("Handling OPTIONS request");
        return Ok(cors_preflight());
    }

    if *req.method() != Method::Get {
        println!("Method not allowed: {}", req.method());
        return Ok(cors_response(405, Some("Method Not Allowed".to_string())));
    }

    println!("Processing GET request");

    println!("Retrieving Valkey configuration");
    let valkey_host = variables::get("valkey_host")?;
    let valkey_password = variables::get("valkey_password")?;

    let valkey_url = format!("redis://:{}@{}/0", valkey_password, valkey_host);

    println!("Connecting to Valkey");
    let conn = redis::Connection::open(&valkey_url)?;

    println!("Retrieving cart items");

    // Construct the KEYS command to get all items (assuming they all have UUIDs as keys)
    let keys_pattern = "*";
    
    // Execute the KEYS command
    let keys_result = match conn.execute("KEYS", &[RedisParameter::Binary(keys_pattern.into())]) {
        Ok(result) => result,
        Err(e) => {
            println!("Error executing Valkey command: {:?}", e);
            return Ok(cors_response(500, Some("Internal Server Error".to_string())));
        }
    };
    
    // Convert RedisResult to String and collect into a Vec
    let keys: Vec<String> = keys_result
        .into_iter()
        .filter_map(|result| match result {
            RedisResult::Binary(bytes) => String::from_utf8(bytes).ok(),
            _ => None,
        })
        .collect();

    println!("Retrieved keys: {:?}", keys);

    // Group keys by their UUID
    let mut grouped_keys: HashMap<String, Vec<String>> = HashMap::new();
    for key in keys {
        let parts: Vec<&str> = key.split(':').collect();
        if parts.len() == 2 {
            grouped_keys.entry(parts[0].to_string())
                .or_insert_with(Vec::new)
                .push(parts[1].to_string());
        }
    }

    let mut cart_items = Vec::new();

    for (uuid, attributes) in grouped_keys {
        if attributes.len() == 3 {
            let mut name = String::new();
            let mut price = 0.0;
            let mut quantity = 0;

            for attr in attributes {
                let value: RedisResult = conn.execute("GET", &[RedisParameter::Binary(format!("{}:{}", uuid, attr).into_bytes())])?
                    .into_iter()
                    .next()
                    .ok_or_else(|| anyhow!("Failed to get value for key {}:{}", uuid, attr))?;

                match attr.as_str() {
                    "name" => {
                        if let RedisResult::Binary(bytes) = value {
                            name = String::from_utf8(bytes).unwrap_or_default();
                        }
                    },
                    "price" => {
                        if let RedisResult::Binary(bytes) = value {
                            if let Ok(s) = String::from_utf8(bytes) {
                                price = s.parse().unwrap_or(0.0);
                            }
                        }
                    },
                    "quantity" => {
                        if let RedisResult::Binary(bytes) = value {
                            if let Ok(s) = String::from_utf8(bytes) {
                                quantity = s.parse().unwrap_or(0);
                            }
                        }
                    },
                    _ => {}
                }
            }

            cart_items.push(CartItem { 
                id: uuid.clone(), 
                name, 
                price, 
                quantity 
            });
        }
    }

    println!("Retrieved cart items: {:?}", cart_items);

    let response_body = json!({
        "items": cart_items
    }).to_string();

    println!("Sending response with body: {}", response_body);
    Ok(cors_response(200, Some(response_body)))
}
