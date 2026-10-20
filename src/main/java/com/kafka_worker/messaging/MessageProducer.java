package com.kafka_worker.messaging;

import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.stereotype.Service;

@Service
public class MessageProducer {

    private static final String TOPIC = "message-sended";

    private final KafkaTemplate<String, String> kafkaTemplate;

    public MessageProducer(
            KafkaTemplate<String, String> kafkaTemplate) {
        this.kafkaTemplate = kafkaTemplate;
    }

    public void publish(String messageId) {
        kafkaTemplate.send(TOPIC, messageId)
                .whenComplete((result, exception) -> {
                    if (exception != null) {
                        System.err.println(
                                "Erro ao publicar mensagem: "
                                        + exception.getMessage());
                        return;
                    }

                    System.out.println(
                            "Mensagem publicada: "
                                    + result.getRecordMetadata()
                                            .offset());
                });
    }
}