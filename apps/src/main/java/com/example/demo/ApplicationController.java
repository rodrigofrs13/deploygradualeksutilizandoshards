package com.example.demo;

import java.util.Map;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class ApplicationController {

    @Value("${app.version:unknown}")
    private String version;

    @Value("${app.shard:unknown}")
    private String shard;

    @GetMapping("/")
    public Map<String, String> home() {
        return Map.of(
            "application", "springboot-sharded-app",
            "message", "teste 3",
            "version", version,
            "shard", shard
        );
    }

    @GetMapping("/health")
    public String health() {
        return "OK";
    }

    @GetMapping("/version")
    public Map<String, String> version() {
        return Map.of(
            "version", version,
            "shard", shard
        );
    }
}
