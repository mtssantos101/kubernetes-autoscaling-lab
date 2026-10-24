package com.kafka_worker.messaging;

import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Component;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;

@Component
public class MessageConsumer {
    private static final Logger logger = LoggerFactory.getLogger(MessageConsumer.class);
    private final Counter consumed;

    public MessageConsumer(MeterRegistry registry) {
        this.consumed = registry.counter(
                "kafka.messages.consumed", "topic", "message.sended");
    }

    @KafkaListener(topics = "message.sended")
    public void consume(String messageId) {
        consumed.increment();
        logger.info("Mensagem recebida pelo consumer: {}", messageId);
    }
}
