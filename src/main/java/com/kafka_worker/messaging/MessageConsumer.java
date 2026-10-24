package com.kafka_worker.messaging;

import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Component;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;

@Component
public class MessageConsumer {
    private final Counter consumed;

    public MessageConsumer(MeterRegistry registry) {
        this.consumed = registry.counter(
                "kafka.messages.consumed", "topic", "message.sended");
    }

    @KafkaListener(topics = "message.sended")
    public void consume(String messageId) {
        consumed.increment();
        System.out.println("Mensagem recebida pelo consumer: " + messageId);
    }
}